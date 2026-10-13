import Foundation
import Testing

@testable import GitHubKit

/// Answers requests from a queue of canned responses and records what was sent.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [(Int, String)]
  /// Fixed answers by URL path, used before the queue.
  private let routes: [String: (Int, String)]
  private(set) var requests: [URLRequest] = []

  init(_ responses: [(Int, String)], routes: [String: (Int, String)] = [:]) {
    self.responses = responses
    self.routes = routes
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (status, body) = try lock.withLock {
      requests.append(request)
      if let route = routes[request.url?.path ?? ""] { return route }
      guard !responses.isEmpty else { throw GitHubError.invalidResponse }
      return responses.removeFirst()
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (Data(body.utf8), response)
  }

  func body(_ index: Int) -> String {
    lock.withLock { requests[index].httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" }
  }
}

let codeResponse = """
  {"device_code":"dc","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device",\
  "expires_in":900,"interval":0}
  """
let userResponse = """
  {"login":"octocat","name":"The Octocat","avatar_url":"https://avatars.githubusercontent.com/u/1",\
  "html_url":"https://github.com/octocat"}
  """

@Suite struct DeviceFlowTests {
  @Test func pollsUntilApproved() async throws {
    let transport = FakeTransport([
      (200, codeResponse),
      (200, #"{"error":"authorization_pending"}"#),
      (200, #"{"error":"slow_down","interval":10}"#),
      (200, #"{"access_token":"gho_token","token_type":"bearer","scope":"repo,read:org"}"#),
    ])
    var flow = DeviceFlow(clientID: "client", transport: transport)
    let waits = Waits()
    flow.sleep = { await waits.append($0) }

    let code = try await flow.start(scopes: ["repo", "read:org"])
    #expect(code.userCode == "ABCD-1234")
    #expect(code.verificationURL.absoluteString == "https://github.com/login/device")
    #expect(transport.body(0) == "client_id=client&scope=repo%20read%3Aorg")

    #expect(try await flow.token(for: code) == DeviceGrant(token: "gho_token", scopes: ["repo", "read:org"]))
    #expect(await waits.values == [.zero, .zero, .seconds(10)])
    #expect(transport.body(3).contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
  }

  @Test func reportsADeclinedSignIn() async throws {
    let transport = FakeTransport([(200, codeResponse), (200, #"{"error":"access_denied"}"#)])
    let flow = DeviceFlow(clientID: "client", transport: transport)
    let code = try await flow.start(scopes: [])
    await #expect(throws: GitHubError.signInDeclined) {
      try await flow.token(for: code)
    }
  }
}

actor Waits {
  var values: [Duration] = []
  func append(_ value: Duration) { values.append(value) }
}

@Suite struct GitHubAPITests {
  @Test func createsAUserRepository() async throws {
    let transport = FakeTransport([
      (
        201,
        """
        {"name":"Git","full_name":"octocat/Git","private":true,"html_url":"https://github.com/octocat/Git",\
        "clone_url":"https://github.com/octocat/Git.git","ssh_url":"git@github.com:octocat/Git.git"}
        """
      )
    ])
    let api = GitHubAPI(token: "t", transport: transport)
    let repository = try await api.createRepository(NewRepository(name: "Git", isPrivate: true))
    #expect(repository.fullName == "octocat/Git" && repository.isPrivate)
    #expect(repository.cloneURL.absoluteString == "https://github.com/octocat/Git.git")

    let request = try #require(transport.requests.first)
    #expect(request.httpMethod == "POST")
    // GitHub refuses API calls whose User-Agent starts with "Git/", URLSession's default for this app.
    let agent = try #require(request.value(forHTTPHeaderField: "User-Agent"))
    #expect(!agent.hasPrefix("Git/") && agent.hasSuffix("GitHubKit"))
    #expect(request.url?.absoluteString == "https://api.github.com/user/repos")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
    let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
    #expect(body?["name"] as? String == "Git" && body?["private"] as? Bool == true)
    #expect(body?["description"] == nil)
  }

  @Test func createsAnOrganizationRepository() async throws {
    let transport = FakeTransport([(500, "")])
    let api = GitHubAPI(token: "t", transport: transport)
    _ = try? await api.createRepository(
      NewRepository(name: "Git", description: "A client", isPrivate: false, organization: "v57-team"))
    #expect(transport.requests.first?.url?.absoluteString == "https://api.github.com/orgs/v57-team/repos")
    #expect(transport.body(0).contains(#""description":"A client""#))
  }

  @Test func explainsFailures() async throws {
    let taken = """
      {"message":"Repository creation failed.","errors":[{"resource":"Repository","code":"custom",\
      "field":"name","message":"name already exists on this account"}]}
      """
    let api = GitHubAPI(token: "t", transport: FakeTransport([(422, taken), (401, "{}"), (403, "<html>")]))
    await #expect(throws: GitHubError.api(status: 422, message: "Name already exists on this account.")) {
      try await api.createRepository(NewRepository(name: "Git", isPrivate: true))
    }
    await #expect(throws: GitHubError.unauthorized) { try await api.user() }
    await #expect(throws: GitHubError.api(status: 403, message: "GitHub refused the request: forbidden (HTTP 403).")) {
      try await api.user()
    }
  }

  @Test func normalizesNamesLikeGitHub() {
    #expect(NewRepository.normalizedName("My Project") == "My-Project")
    #expect(NewRepository.normalizedName("  a  b!c.d_e ") == "a-b-c.d_e")
    #expect(NewRepository.normalizedName("Café") == "Caf-")
  }
}

@Suite struct PermissionTests {
  @Test func readsGrantedScopes() {
    let all = GitHubPermissions(scopes: ["repo", "admin:org", "workflow"])
    #expect(all == .recommended)
    let publicOnly = GitHubPermissions(scopes: ["public_repo"])
    #expect(publicOnly == GitHubPermissions(repositories: .publicOnly, organizations: false, workflows: false))
    #expect(GitHubPermissions.parse("repo, read:org") == ["repo", "read:org"])
    #expect(GitHubPermissions.parse("repo,workflow") == ["repo", "workflow"])
  }

  @Test func comparesAndCombines() {
    let publicOnly = GitHubPermissions(repositories: .publicOnly, organizations: true, workflows: false)
    #expect(GitHubPermissions.recommended.includes(publicOnly))
    #expect(!publicOnly.includes(.recommended))
    #expect(publicOnly.union(GitHubPermissions(repositories: .none, organizations: false, workflows: true))
      == GitHubPermissions(repositories: .publicOnly, organizations: true, workflows: true))
    #expect(publicOnly.scopes == ["public_repo", "read:org"])
    #expect(GitHubPermissions.recommended.scopes == ["repo", "read:org", "workflow"])
  }
}

/// Responds to `/user` with the token's scopes, as GitHub does.
final class ScopedTransport: HTTPTransport, @unchecked Sendable {
  let inner: FakeTransport
  let scopes: String
  init(_ inner: FakeTransport, scopes: String) {
    self.inner = inner
    self.scopes = scopes
  }
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await inner.send(request)
    var headers = response.allHeaderFields as? [String: String] ?? [:]
    if request.url?.path == "/user" { headers["X-OAuth-Scopes"] = scopes }
    let scoped = HTTPURLResponse(
      url: response.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: headers)!
    return (data, scoped)
  }
}

@MainActor @Suite struct GitHubAccountTests {
  func waitForSignIn(_ account: GitHubAccount) async throws {
    while true {
      switch account.signInStep {
      case .succeeded, .failed: return
      default: try await Task.sleep(for: .milliseconds(10))
      }
    }
  }

  @Test func signsInSavesAndSignsOut() async throws {
    let transport = ScopedTransport(
      FakeTransport(
        [(200, codeResponse), (200, #"{"access_token":"gho_token","scope":"repo,read:org"}"#)],
        // By path: refresh() asks for the profile and the organizations at the same time.
        routes: ["/user": (200, userResponse), "/user/orgs": (200, #"[{"login":"octo-org"}]"#)]),
      scopes: "repo, read:org")
    let store = MemoryTokenStore()
    let account = GitHubAccount(clientID: "client", store: store, transport: transport)
    var credentials: [GitHubCredential?] = []
    account.onCredentialChange = { credentials.append($0) }

    account.signIn(requesting: .recommended)
    try await waitForSignIn(account)
    while account.organizations.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

    #expect(account.signInStep == .succeeded(requested: .recommended))
    // Workflows was requested but not granted.
    #expect(account.permissions == GitHubPermissions(repositories: .all, organizations: true, workflows: false))
    #expect(account.user?.name == "The Octocat")
    #expect(account.organizations.map(\.login) == ["octo-org"])
    let credential = GitHubCredential(login: "octocat", token: "gho_token", scopes: ["repo", "read:org"])
    #expect(try store.load() == credential)
    #expect(credentials == [credential])

    account.endSignIn()
    #expect(account.signInStep == nil)
    account.signOut()
    #expect(!account.isSignedIn && account.credential == nil)
    #expect(try store.load() == nil)
    #expect(credentials == [credential, nil])
  }

  @Test func aFailedReauthorizationKeepsTheAccount() async throws {
    let credential = GitHubCredential(login: "octocat", token: "old", scopes: ["repo"])
    let transport = FakeTransport(
      [(200, codeResponse), (200, #"{"error":"expired_token"}"#)],
      routes: ["/user": (503, ""), "/user/orgs": (503, "")])
    let account = GitHubAccount(clientID: "client", store: MemoryTokenStore(credential), transport: transport)
    account.restore()
    account.signIn(requesting: .recommended)
    try await waitForSignIn(account)
    #expect(account.signInStep == .failed(.codeExpired))
    #expect(account.credential == credential)
  }

  @Test func restoresTheSavedCredential() {
    let credential = GitHubCredential(login: "octocat", token: "gho_token", scopes: ["public_repo"])
    let account = GitHubAccount(
      clientID: "client", store: MemoryTokenStore(credential), transport: FakeTransport([]))
    account.restore()
    #expect(account.isSignedIn && account.credential == credential)
    #expect(account.permissions.repositories == .publicOnly)
    #expect(account.user?.login == "octocat")
  }
}
