import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The code the user enters at `verificationURL` to let the app sign in.
public struct DeviceCode: Sendable, Hashable {
  /// What the user types on github.com, e.g. `154C-87C2`.
  public var userCode: String
  public var verificationURL: URL
  public var expiresAt: Date
  /// How long to wait between polls.
  public var interval: Duration
  let deviceCode: String
}

/// What the device flow ends with: the token and the scopes GitHub granted, which may be fewer
/// than were requested.
public struct DeviceGrant: Sendable, Hashable {
  public var token: String
  public var scopes: Set<String>
}

/// OAuth device flow (RFC 8628) against github.com: the app shows a code, the user approves it
/// in the browser, and the app polls for the token. It needs only the OAuth App's public client
/// ID, so no secret ships in the app.
public struct DeviceFlow: Sendable {
  static let codeURL = URL(string: "https://github.com/login/device/code")!
  static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!

  public var clientID: String
  let transport: any HTTPTransport
  /// Waits between polls; tests skip the wait.
  var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

  public init(clientID: String, transport: any HTTPTransport = URLSession.shared) {
    self.clientID = clientID
    self.transport = transport
  }

  /// Asks GitHub for a code to show the user, for a token with `scopes`.
  public func start(scopes: [String]) async throws -> DeviceCode {
    struct Response: Decodable {
      var device_code: String?
      var user_code: String?
      var verification_uri: String?
      var expires_in: Int?
      var interval: Int?
      var error: String?
      var error_description: String?
    }
    let request = URLRequest.form(
      Self.codeURL, [("client_id", clientID), ("scope", scopes.joined(separator: " "))])
    let response: Response = try await post(request)
    guard let deviceCode = response.device_code, let userCode = response.user_code,
      let uri = response.verification_uri, let verificationURL = URL(string: uri)
    else {
      throw GitHubError.signIn(
        response.error_description ?? response.error.map(Self.describe)
          ?? "GitHub didn't return a sign-in code.")
    }
    return DeviceCode(
      userCode: userCode, verificationURL: verificationURL,
      expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in ?? 900)),
      interval: .seconds(response.interval ?? 5), deviceCode: deviceCode)
  }

  /// Polls until the user approves the code and returns the access token. Throws when the user
  /// declines, the code expires, or the task is cancelled.
  public func token(for code: DeviceCode) async throws -> DeviceGrant {
    struct Response: Decodable {
      var access_token: String?
      var scope: String?
      var error: String?
      var error_description: String?
      var interval: Int?
    }
    var interval = code.interval
    while true {
      try await sleep(interval)
      guard Date() < code.expiresAt else { throw GitHubError.codeExpired }
      let request = URLRequest.form(
        Self.tokenURL,
        [
          ("client_id", clientID), ("device_code", code.deviceCode),
          ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
        ])
      let response: Response = try await post(request)
      if let token = response.access_token, !token.isEmpty {
        return DeviceGrant(token: token, scopes: GitHubPermissions.parse(response.scope ?? ""))
      }
      switch response.error {
      case "authorization_pending":
        continue
      case "slow_down":
        interval = response.interval.map { .seconds($0) } ?? interval + .seconds(5)
      case "access_denied":
        throw GitHubError.signInDeclined
      case "expired_token":
        throw GitHubError.codeExpired
      case let error?:
        throw GitHubError.signIn(Self.describe(error))
      case nil:
        throw GitHubError.invalidResponse
      }
    }
  }

  private func post<Response: Decodable>(_ request: URLRequest) async throws -> Response {
    let (data, response) = try await transport.send(request)
    guard (200..<300).contains(response.statusCode) else {
      throw GitHubError.from(status: response.statusCode, body: data)
    }
    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw GitHubError.invalidResponse
    }
  }

  static func describe(_ error: String) -> String {
    switch error {
    case "device_flow_disabled": "Device sign-in is turned off for this app on GitHub."
    case "incorrect_client_credentials": "GitHub doesn't recognize this app's client ID."
    default: "GitHub sign-in failed (\(error))."
    }
  }
}
