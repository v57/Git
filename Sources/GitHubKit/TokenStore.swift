import Foundation

#if canImport(Security)
  import Security
#else
  import VaultKit
#endif

/// Keeps the signed-in login and token.
public protocol TokenStore: Sendable {
  func load() throws -> GitHubCredential?
  func save(_ credential: GitHubCredential) throws
  func delete() throws
}

/// One generic-password item, named after `service`.
///
/// Without an access group the item is in the login keychain and its access list trusts only the
/// app's code signature: other processes get a macOS prompt instead of the token, unlike
/// `gh auth token` or `git credential fill`, which hand theirs to any process that asks.
///
/// With an access group (`AUCR797TMH.dev.v57.shared`) the item is in the data-protection keychain,
/// readable by every app signed by the team that lists the group, and synced through iCloud
/// Keychain: one sign-in serves Git, Markdown and Dev on all the user's devices. A build that
/// isn't entitled to the group (ad-hoc signed) keeps its own item instead.
#if canImport(Security)
public struct KeychainTokenStore: TokenStore {
  public let service: String
  public let accessGroup: String?

  public init(service: String, accessGroup: String? = nil) {
    self.service = service
    self.accessGroup = accessGroup
  }

  /// The v57 apps' shared GitHub sign-in.
  public static let shared = KeychainTokenStore(
    service: "dev.v57.github", accessGroup: "AUCR797TMH.dev.v57.shared")

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
    if item[kSecAttrSynchronizable] != nil { item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock }
    try check(SecItemAdd(item as CFDictionary, nil))
  }

  public func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    if status != errSecItemNotFound { try check(status) }
  }

  private var baseQuery: [CFString: Any] {
    var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
    if let accessGroup, Self.isEntitled(to: accessGroup) {
      query[kSecUseDataProtectionKeychain] = true
      query[kSecAttrAccessGroup] = accessGroup
      query[kSecAttrSynchronizable] = true
    }
    return query
  }

  /// Whether the app may use the group (a probe answers errSecMissingEntitlement otherwise).
  private static func isEntitled(to group: String) -> Bool {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: "dev.v57.github.probe",
      kSecUseDataProtectionKeychain: true, kSecAttrAccessGroup: group,
    ]
    return SecItemCopyMatching(query as CFDictionary, nil) != errSecMissingEntitlement
  }

  private func check(_ status: OSStatus) throws {
    guard status != errSecSuccess else { return }
    let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    throw GitHubError.signIn(message)
  }
}
#else
  /// One item in the system's credential store (VaultKit's keychain: the Windows Credential Manager), named after
  /// `service`: the login, the scopes and the token. Every v57 app of the user reads the shared one.
  public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) {
      self.service = service
      self.accessGroup = accessGroup
    }

    public static let shared = KeychainTokenStore(
      service: "dev.v57.github", accessGroup: "AUCR797TMH.dev.v57.shared")

    private struct Item: Codable {
      var login: String
      var token: String
      var scopes: [String]
    }

    private var keychain: VaultKeychain { VaultKeychain(service: service) }

    public func load() throws -> GitHubCredential? {
      do {
        guard let data = try keychain.read("credential", options: .thisDevice),
          let item = try? JSONDecoder().decode(Item.self, from: data)
        else { return nil }
        return GitHubCredential(login: item.login, token: item.token, scopes: Set(item.scopes))
      } catch {
        throw GitHubError.signIn(error.localizedDescription)
      }
    }

    public func save(_ credential: GitHubCredential) throws {
      let item = Item(login: credential.login, token: credential.token, scopes: credential.scopes.sorted())
      do {
        try keychain.write(try JSONEncoder().encode(item), account: "credential", options: .thisDevice)
      } catch {
        throw GitHubError.signIn(error.localizedDescription)
      }
    }

    public func delete() throws {
      do { try keychain.delete("credential", options: .thisDevice) } catch { throw GitHubError.signIn(error.localizedDescription) }
    }
  }
#endif

extension KeychainTokenStore {
  /// The vault account Personal is (`VaultAccount.personal.id`).
  public static let personalAccountID = "personal"

  /// The GitHub sign-in of one vault account. Personal's is `shared`, unchanged; another account's sits beside it
  /// under its own service (`dev.v57.github.<accountID>`, same access group), so signing in or out there leaves
  /// Personal's alone, and every v57 app finds the same item for the account.
  public static func forAccount(_ accountID: String) -> KeychainTokenStore {
    guard accountID != personalAccountID else { return shared }
    return KeychainTokenStore(service: "\(shared.service).\(accountID)", accessGroup: shared.accessGroup)
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
