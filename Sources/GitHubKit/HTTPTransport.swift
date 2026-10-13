import Foundation

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
  /// A form-encoded POST that asks for JSON back, as GitHub's OAuth endpoints take.
  static func form(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
    var request = URLRequest(url: url)
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
