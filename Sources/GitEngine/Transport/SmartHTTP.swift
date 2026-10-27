import Foundation
import GitKit

/// A ref a server advertises.
struct RemoteRef: Equatable {
  var name: String
  var id: ObjectID
  /// For `HEAD`: the branch it points to.
  var symrefTarget: String?
  /// For an annotated tag: the object it points to.
  var peeled: ObjectID?
}

/// git's smart HTTP protocol over URLSession: `GET info/refs?service=…` to discover, `POST <service>` to talk.
/// Credentials come from `GitCredentials` for the URL's host and go out as HTTP Basic authentication.
final class SmartHTTP: Sendable {
  /// The repository URL without a trailing slash, after redirects and an added `.git` when that was needed.
  let baseURL: URL
  private let session: URLSession

  static let agent = "git/2.45.0-GitEngine"

  private init(baseURL: URL, session: URLSession) {
    self.baseURL = baseURL
    self.session = session
  }

  /// The advertisement of a service, and a transport whose URL is the one that answered.
  static func discover(_ remote: String, service: String, version2: Bool) async throws -> (SmartHTTP, Data) {
    var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasSuffix("/") { text.removeLast() }
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
      url.host != nil
    else {
      throw GitEngineError.refused("“\(remote)” isn't an HTTPS address. Only HTTPS remotes work on this device.")
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 120
    let session = URLSession(configuration: configuration)
    var candidates = [url]
    if !url.path.hasSuffix(".git") { candidates.append(URL(string: text + ".git")!) }
    var lastError: (any Error)?
    for candidate in candidates {
      let transport = SmartHTTP(baseURL: candidate, session: session)
      do {
        return try await transport.advertise(service: service, version2: version2)
      } catch let error as GitEngineError where error.kind == .notFound {
        lastError = error
      }
    }
    throw lastError ?? GitEngineError.network("Couldn't reach \(remote).")
  }

  private func advertise(service: String, version2: Bool) async throws -> (SmartHTTP, Data) {
    var components = URLComponents(url: baseURL.appendingPathComponent("info/refs"), resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "service", value: service)]
    var request = request(components.url!)
    if version2 { request.setValue("version=2", forHTTPHeaderField: "Git-Protocol") }
    let (data, response) = try await load(request)
    try check(response, data: data)
    guard response.mimeType == "application/x-\(service)-advertisement" else {
      throw GitEngineError.network("\(baseURL.host ?? "The server") doesn't speak git's smart HTTP protocol.")
    }
    // Follow a redirect for the later POSTs too.
    var finalURL = baseURL
    if let redirected = response.url, redirected.path.hasSuffix("/info/refs") {
      var components = URLComponents(url: redirected, resolvingAgainstBaseURL: false)!
      components.query = nil
      components.path = String(components.path.dropLast("/info/refs".count))
      finalURL = components.url ?? baseURL
    }
    return (finalURL == baseURL ? self : SmartHTTP(baseURL: finalURL, session: session), data)
  }

  /// POSTs `body` to `service` and returns the response's bytes as they arrive.
  func post(_ service: String, body: Data, version2: Bool) async throws -> URLSession.AsyncBytes {
    var request = request(baseURL.appendingPathComponent(service))
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/x-\(service)-request", forHTTPHeaderField: "Content-Type")
    request.setValue("application/x-\(service)-result", forHTTPHeaderField: "Accept")
    if version2 { request.setValue("version=2", forHTTPHeaderField: "Git-Protocol") }
    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
    do {
      (bytes, response) = try await session.bytes(for: request)
    } catch {
      throw Self.networkError(error, host: baseURL.host)
    }
    guard let http = response as? HTTPURLResponse else {
      throw GitEngineError.network("The server's answer was empty.")
    }
    if http.statusCode != 200 {
      var data = Data()
      for try await byte in bytes where data.count < 4096 { data.append(byte) }
      try check(http, data: data)
    }
    return bytes
  }

  private func request(_ url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    if let host = baseURL.host, let credential = GitCredentials.credential(for: host) {
      let token = Data("\(credential.username):\(credential.password)".utf8).base64EncodedString()
      request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  private var hasCredential: Bool { baseURL.host.flatMap(GitCredentials.credential(for:)) != nil }

  private func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw GitEngineError.network("The server's answer was empty.")
      }
      return (data, http)
    } catch let error as GitEngineError {
      throw error
    } catch {
      throw Self.networkError(error, host: baseURL.host)
    }
  }

  static func networkError(_ error: any Error, host: String?) -> GitEngineError {
    if let error = error as? GitEngineError { return error }
    return GitEngineError.network("Couldn't reach \(host ?? "the server"): \(error.localizedDescription)")
  }

  /// Turns an HTTP failure into a message: sign in for 401/403, not found for 404.
  private func check(_ response: HTTPURLResponse, data: Data) throws {
    let host = baseURL.host ?? "the server"
    switch response.statusCode {
    case 200: return
    case 401, 403:
      throw GitEngineError(
        .authentication,
        hasCredential
          ? "\(host) refused the sign-in. Sign in again, or check that the account can access this repository."
          : "\(host) needs you to sign in to access this repository.")
    case 404:
      throw GitEngineError(
        .notFound,
        hasCredential
          ? "\(host) has no repository at \(baseURL.path)."
          : "\(host) has no repository at \(baseURL.path), or it's private: sign in to access it.")
    default:
      let detail = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      throw GitEngineError.network(
        "\(host) answered with HTTP \(response.statusCode)" + (detail.isEmpty ? "." : ": \(detail)"))
    }
  }
}
