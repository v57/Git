import Foundation
import ComponentKit
import GitHubKit
import GitKit
import VaultKit

extension GitHubAccount {
  /// Personal's sign-in: the v57 apps' shared one (`KeychainTokenStore.shared`, in the shared keychain group and
  /// iCloud Keychain), so Markdown and Dev are signed in too. The iPhone and iPad app has only this one.
  public static var app: GitHubAccount { forAccount(KeychainTokenStore.personalAccountID) }

  private static var signIns: [String: GitHubAccount] = [:]

  /// The GitHub sign-in of a vault account (`KeychainTokenStore.forAccount`, the one Markdown and Dev use for it),
  /// made and restored the first time a window or Settings asks for it. With access to private repositories, git
  /// uses it for github.com over HTTPS in that account's repositories (`GitCredentials`' account, nil for
  /// Personal) instead of gh or osxkeychain; a token limited to public repositories can't push to private ones, so
  /// git keeps the user's own credentials then.
  public static func forAccount(_ accountID: String) -> GitHubAccount {
    if let account = signIns[accountID] { return account }
    let isPersonal = accountID == KeychainTokenStore.personalAccountID
    let account = GitHubAccount(
      // The "Git" OAuth App (github.com/settings/applications/3928259), with device flow on.
      clientID: "Ov23liDnMAUwLO9o0eyX", store: KeychainTokenStore.forAccount(accountID))
    let gitAccount = isPersonal ? nil : accountID
    account.onCredentialChange = { credential in
      let forGit = credential.flatMap { $0.permissions.repositories == .all ? $0 : nil }
      GitCredentials.set(
        forGit.map { GitCredential(username: $0.login, password: $0.token) }, for: "github.com", account: gitAccount)
    }
    signIns[accountID] = account
    #if DEBUG
      // Screenshots and test launches don't touch the keychain.
      if ProcessInfo.processInfo.arguments.contains("--in-memory") { return account }
    #endif
    if isPersonal { moveLegacyToken() }
    account.restore()
    return account
  }

  /// Moves a token saved by builds before the shared sign-in into it.
  private static func moveLegacyToken() {
    let legacy = KeychainTokenStore(service: "Git: GitHub account")
    guard (try? KeychainTokenStore.shared.load()) == nil, let credential = try? legacy.load() else { return }
    if (try? KeychainTokenStore.shared.save(credential)) != nil { try? legacy.delete() }
  }

  /// The vault account this sign-in is (nil for one made elsewhere).
  var vaultAccountID: String? { Self.signIns.first { $0.value === self }?.key }

  /// The sign-ins the other vault accounts have, one per GitHub login, Personal's first: a signed-out account
  /// offers them, so the user needn't sign in to GitHub again.
  var signInOffers: [GitHubSignInOffer] {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--in-memory") { return [] }
    #endif
    guard !isSignedIn, let own = vaultAccountID else { return [] }
    let others = Vaults.shared.allAccounts.filter { $0.id != own }
    return KeychainTokenStore.signIns(of: others.map(\.id)).compactMap { signIn in
      others.first { $0.id == signIn.accountID }.map {
        GitHubSignInOffer(accountName: $0.name, credential: signIn.credential)
      }
    }
  }

  /// Signs in with another account's sign-in: this account keeps a copy of its own.
  func use(_ offer: GitHubSignInOffer) {
    do {
      try signIn(with: offer.credential)
      Task { await refresh() }
    } catch {
      notice = (error as? GitHubError)?.errorDescription ?? error.localizedDescription
    }
  }

  /// Starts the device flow, then copies the code and opens github.com's page to enter it.
  func signInInBrowser(requesting permissions: GitHubPermissions) {
    signIn(requesting: permissions) { [weak self] code in self?.openVerificationPage(code) }
  }

  func openVerificationPage(_ code: DeviceCode) {
    copy(code)
    KitDesktop.open(code.verificationURL)
  }

  func copy(_ code: DeviceCode) {
    KitPasteboard.copy(code.userCode)
  }
}

/// A GitHub sign-in another vault account has, which one without a sign-in can use too.
struct GitHubSignInOffer: Identifiable {
  var accountName: String
  var credential: GitHubCredential
  var id: String { credential.login }
}

/// A sign-in sheet to show, starting from `permissions`.
public struct GitHubSignInRequest: Identifiable {
  public let id = UUID()
  public var permissions: GitHubPermissions

  public init(permissions: GitHubPermissions) {
    self.permissions = permissions
  }
}

/// One permission the app can ask for, as Settings and the sign-in sheet name it.
public enum GitHubPermission: CaseIterable, Identifiable {
  case privateRepositories, organizations, workflows

  public var id: Self { self }

  public var title: String {
    switch self {
    case .privateRepositories: "Private repositories"
    case .organizations: "Organizations"
    case .workflows: "Workflows"
    }
  }

  public var scope: String {
    switch self {
    case .privateRepositories: "repo"
    case .organizations: "read:org"
    case .workflows: "workflow"
    }
  }

  public var detail: String {
    switch self {
    case .privateRepositories: "Read and write every repository you can access."
    case .organizations: "List your organizations and publish repositories to them."
    case .workflows: "Push changes to GitHub Actions files in .github/workflows."
    }
  }

  /// The permissions with just this one turned on.
  public var permissions: GitHubPermissions {
    switch self {
    case .privateRepositories: GitHubPermissions(repositories: .all, organizations: false, workflows: false)
    case .organizations: GitHubPermissions(repositories: .none, organizations: true, workflows: false)
    case .workflows: GitHubPermissions(repositories: .none, organizations: false, workflows: true)
    }
  }

  public func isGranted(in permissions: GitHubPermissions) -> Bool {
    permissions.includes(self.permissions)
  }
}
