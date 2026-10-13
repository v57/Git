import Foundation

public enum GitHubError: Error, Sendable, Hashable, LocalizedError {
  /// The token was revoked or expired (HTTP 401).
  case unauthorized
  /// The user declined the sign-in on github.com.
  case signInDeclined
  /// The sign-in code expired before the user entered it.
  case codeExpired
  /// The API refused a request; `message` is GitHub's explanation.
  case api(status: Int, message: String)
  /// Sign-in failed or was declined.
  case signIn(String)
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .unauthorized: "Your GitHub sign-in has expired or was revoked. Sign in again."
    case .signInDeclined: "GitHub didn’t give Git access. Try again, or cancel to keep using your git credentials."
    case .codeExpired: "Codes last 15 minutes. Try again to get a new one; nothing was changed."
    case .api(_, let message): message
    case .signIn(let message): message
    case .invalidResponse: "GitHub sent a response this app doesn't understand."
    }
  }

  /// The error for a failed API response, using the most specific message in its body:
  /// `{"message": "Repository creation failed.", "errors": [{"message": "name already exists…"}]}`.
  static func from(status: Int, body: Data) -> GitHubError {
    if status == 401 { return .unauthorized }
    struct Body: Decodable {
      struct Detail: Decodable {
        var message: String?
        var field: String?
        var code: String?
      }
      var message: String?
      var errors: [Detail]?
    }
    let decoded = try? JSONDecoder().decode(Body.self, from: body)
    let details = (decoded?.errors ?? []).compactMap { detail -> String? in
      if let message = detail.message { return message }
      if let field = detail.field, detail.code == "already_exists" { return "\(field) already exists" }
      return nil
    }
    if details.isEmpty, decoded?.message == nil {
      // No JSON explanation (GitHub sends an HTML page for some refusals).
      let reason = sentence(HTTPURLResponse.localizedString(forStatusCode: status)).dropLast()
      return .api(status: status, message: "GitHub refused the request: \(reason.lowercased()) (HTTP \(status)).")
    }
    let message = details.isEmpty ? decoded?.message ?? "" : details.joined(separator: "\n")
    return .api(status: status, message: sentence(message))
  }

  /// "name already exists on this account" → "Name already exists on this account."
  private static func sentence(_ text: String) -> String {
    var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = text.first else { return text }
    text = first.uppercased() + text.dropFirst()
    if let last = text.last, !".!?".contains(last) { text += "." }
    return text
  }
}
