import ComponentKit
import Foundation
import GitHubKit

/// One permission an app can ask for, as settings and the sign-in sheet name it.
public enum GitHubPermission: CaseIterable, Identifiable, Sendable {
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

  /// The icon of its row in the sign-in sheet.
  var systemImage: String {
    switch self {
    case .privateRepositories: "lock"
    case .organizations: "person.3"
    case .workflows: "gearshape.2"
    }
  }

  var hue: Hue {
    switch self {
    case .privateRepositories: .gray
    case .organizations: .blue
    case .workflows: .orange
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

/// A sign-in sheet to show, starting from `permissions`: `.kitSheet(item:)`'s item.
public struct GitHubSignInRequest: Identifiable {
  public let id = UUID()
  public var permissions: GitHubPermissions

  public init(permissions: GitHubPermissions) {
    self.permissions = permissions
  }
}

/// A GitHub sign-in another vault account has, which one without a sign-in can use too.
public struct GitHubSignInOffer: Identifiable {
  /// The vault account's name.
  public var accountName: String
  public var credential: GitHubCredential
  public var id: String { credential.login }

  public init(accountName: String, credential: GitHubCredential) {
    self.accountName = accountName
    self.credential = credential
  }
}

extension GitHubAccount {
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
