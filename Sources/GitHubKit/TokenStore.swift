import Foundation
import Security

/// Keeps the signed-in login and token.
public protocol TokenStore: Sendable {
  func load() throws -> GitHubCredential?
  func save(_ credential: GitHubCredential) throws
  func delete() throws
}

/// One generic-password item in the login keychain, named after `service`.
///
/// The item is created by the app, so its access list trusts only the app's code signature:
/// other processes get a macOS prompt instead of the token, unlike `gh auth token` or
/// `git credential fill`, which hand theirs to any process that asks.
public struct KeychainTokenStore: TokenStore {
  public let service: String

  public init(service: String) {
    self.service = service
  }

  public func load() throws -> GitHubCredential? {
    var query = baseQuery
    query[kSecReturnAttributes] = true
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    try check(status)
    guard let item = result as? [CFString: Any], let login = item[kSecAttrAccount] as? String,
      let data = item[kSecValueData] as? Data, let token = String(data: data, encoding: .utf8)
    else { return nil }
    let scopes = GitHubPermissions.parse(item[kSecAttrComment] as? String ?? "")
    return GitHubCredential(login: login, token: token, scopes: scopes)
  }

  public func save(_ credential: GitHubCredential) throws {
    try delete()
    var item = baseQuery
    item[kSecAttrAccount] = credential.login
    item[kSecAttrLabel] = "\(service) (\(credential.login))"
    item[kSecAttrComment] = credential.scopes.sorted().joined(separator: " ")
    item[kSecValueData] = Data(credential.token.utf8)
    try check(SecItemAdd(item as CFDictionary, nil))
  }

  public func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    if status != errSecItemNotFound { try check(status) }
  }

  private var baseQuery: [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
  }

  private func check(_ status: OSStatus) throws {
    guard status != errSecSuccess else { return }
    let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    throw GitHubError.signIn(message)
  }
}

/// Keeps the credential in memory, for tests and previews.
public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var credential: GitHubCredential?

  public init(_ credential: GitHubCredential? = nil) {
    self.credential = credential
  }

  public func load() throws -> GitHubCredential? { lock.withLock { credential } }
  public func save(_ credential: GitHubCredential) throws { lock.withLock { self.credential = credential } }
  public func delete() throws { lock.withLock { credential = nil } }
}
