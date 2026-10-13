import Foundation

/// The parts of GitHub's REST API the apps use, authenticated with a user's token, or anonymous
/// (public repositories only, 60 requests an hour) without one.
public struct GitHubAPI: Sendable {
  public static let baseURL = URL(string: "https://api.github.com")!

  public let token: String?
  let transport: any HTTPTransport

  public init(token: String?, transport: any HTTPTransport = URLSession.shared) {
    self.token = token
    self.transport = transport
  }

  /// The signed-in user.
  public func user() async throws -> GitHubUser {
    try await send("GET", "/user")
  }

  /// The signed-in user and the scopes the token has (from `X-OAuth-Scopes`), which change when
  /// the user edits the authorization on github.com.
  public func userAndScopes() async throws -> (user: GitHubUser, scopes: Set<String>?) {
    let (user, response): (GitHubUser, HTTPURLResponse) = try await request("GET", "/user")
    let header = response.value(forHTTPHeaderField: "X-OAuth-Scopes")
    return (user, header.map(GitHubPermissions.parse))
  }

  /// Organizations the user belongs to (the first 100), which may own new repositories.
  public func organizations() async throws -> [GitHubOrganization] {
    try await send("GET", "/user/orgs?per_page=100")
  }

  /// Creates an empty repository for the user or `repository.organization`.
  public func createRepository(_ repository: NewRepository) async throws -> GitHubRepository {
    struct Body: Encodable {
      var name: String
      var description: String?
      var `private`: Bool
    }
    let body = Body(
      name: repository.name,
      description: repository.description.isEmpty ? nil : repository.description,
      private: repository.isPrivate)
    let path = repository.organization.map { "/orgs/\(Self.pathComponent($0))/repos" } ?? "/user/repos"
    return try await send("POST", path, body: body)
  }

  // MARK: Requests

  func send<Response: Decodable>(
    _ method: String, _ path: String, body: (any Encodable)? = nil
  ) async throws -> Response {
    try await request(method, path, body: body).0
  }

  func request<Response: Decodable>(
    _ method: String, _ path: String, body: (any Encodable)? = nil
  ) async throws -> (Response, HTTPURLResponse) {
    let (data, response) = try await raw(method, path, body: body)
    do {
      return (try JSONDecoder().decode(Response.self, from: data), response)
    } catch {
      throw GitHubError.invalidResponse
    }
  }

  /// The response body as GitHub sent it. `accept` overrides the JSON media type, e.g.
  /// `application/vnd.github.raw+json` for a blob's bytes.
  func raw(
    _ method: String, _ path: String, body: (any Encodable)? = nil, accept: String? = nil
  ) async throws -> (Data, HTTPURLResponse) {
    guard let url = URL(string: path, relativeTo: Self.baseURL) else {
      throw GitHubError.invalidResponse
    }
    var request = URLRequest.gitHub(url)
    request.httpMethod = method
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    request.setValue(accept ?? "application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(body)
    }
    let (data, response) = try await transport.send(request)
    guard (200..<300).contains(response.statusCode) else {
      throw GitHubError.from(status: response.statusCode, body: data)
    }
    return (data, response)
  }

  static func pathComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? value
  }
}
