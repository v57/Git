import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Sends HTTP requests; `URLSession` in the app, a fake in tests.
public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await data(for: request)
    guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
    return (data, http)
  }
}

extension URLRequest {
  /// The app's bundle identifier and version. GitHub requires a User-Agent and refuses API calls
  /// whose agent starts with `Git/`, which URLSession's default (the app's name) is for an app
  /// called Git.
  static let gitHubUserAgent: String = {
    let bundle = Bundle.main
    let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    return "\(bundle.bundleIdentifier ?? "GitHubKit")/\(version) GitHubKit"
  }()

  /// A request to GitHub, with the app's User-Agent.
  static func gitHub(_ url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue(gitHubUserAgent, forHTTPHeaderField: "User-Agent")
    return request
  }

  /// A form-encoded POST that asks for JSON back, as GitHub's OAuth endpoints take.
  static func form(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
    var request = URLRequest.gitHub(url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    request.httpBody = fields
      .map { key, value in
        "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
      }
      .joined(separator: "&")
      .data(using: .utf8)
    return request
  }
}
