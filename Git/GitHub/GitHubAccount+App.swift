import AppKit
import ComponentKit
import GitHubKit
import GitKit

extension GitHubAccount {
  /// The app's account. Its token is the v57 apps' shared sign-in (`KeychainTokenStore.shared`, in
  /// the shared keychain group and iCloud Keychain), so Markdown and Dev are signed in too. With
  /// access to private repositories, git uses it for github.com over HTTPS instead of gh or
  /// osxkeychain; a token limited to public repositories can't push to private ones, so git keeps
  /// the user's own credentials then.
  static let app: GitHubAccount = {
    let account = GitHubAccount(
      // The "Git" OAuth App (github.com/settings/applications/3928259), with device flow on.
      clientID: "Ov23liDnMAUwLO9o0eyX", store: KeychainTokenStore.shared)
    account.onCredentialChange = { credential in
      let forGit = credential.flatMap { $0.permissions.repositories == .all ? $0 : nil }
      GitCredentials.set(
        forGit.map { GitCredential(username: $0.login, password: $0.token) }, for: "github.com")
    }
    #if DEBUG
      // Screenshots and test launches don't touch the keychain.
      if ProcessInfo.processInfo.arguments.contains("--in-memory") { return account }
    #endif
    moveLegacyToken()
    account.restore()
    return account
  }()

  /// Moves a token saved by builds before the shared sign-in into it.
  private static func moveLegacyToken() {
    let legacy = KeychainTokenStore(service: "Git: GitHub account")
    guard (try? KeychainTokenStore.shared.load()) == nil, let credential = try? legacy.load() else { return }
    if (try? KeychainTokenStore.shared.save(credential)) != nil { try? legacy.delete() }
  }

  /// Starts the device flow, then copies the code and opens github.com's page to enter it.
  func signInInBrowser(requesting permissions: GitHubPermissions) {
    signIn(requesting: permissions) { [weak self] code in self?.openVerificationPage(code) }
  }

  func openVerificationPage(_ code: DeviceCode) {
    copy(code)
    NSWorkspace.shared.open(code.verificationURL)
  }

  func copy(_ code: DeviceCode) {
    KitPasteboard.copy(code.userCode)
  }
}

/// A sign-in sheet to show, starting from `permissions`.
struct GitHubSignInRequest: Identifiable {
  let id = UUID()
  var permissions: GitHubPermissions
}

/// One permission the app can ask for, as Settings and the sign-in sheet name it.
enum GitHubPermission: CaseIterable, Identifiable {
  case privateRepositories, organizations, workflows

  var id: Self { self }

  var title: String {
    switch self {
    case .privateRepositories: "Private repositories"
    case .organizations: "Organizations"
    case .workflows: "Workflows"
    }
  }

  var scope: String {
    switch self {
    case .privateRepositories: "repo"
    case .organizations: "read:org"
    case .workflows: "workflow"
    }
  }

  var detail: String {
    switch self {
    case .privateRepositories: "Read and write every repository you can access."
    case .organizations: "List your organizations and publish repositories to them."
    case .workflows: "Push changes to GitHub Actions files in .github/workflows."
    }
  }

  /// The permissions with just this one turned on.
  var permissions: GitHubPermissions {
    switch self {
    case .privateRepositories: GitHubPermissions(repositories: .all, organizations: false, workflows: false)
    case .organizations: GitHubPermissions(repositories: .none, organizations: true, workflows: false)
    case .workflows: GitHubPermissions(repositories: .none, organizations: false, workflows: true)
    }
  }

  func isGranted(in permissions: GitHubPermissions) -> Bool {
    permissions.includes(self.permissions)
  }
}
