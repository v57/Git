import Foundation

/// What the app may do with a GitHub account, as OAuth scopes: which repositories, organizations
/// and workflow files. Used both for what to request and for what GitHub actually granted.
public struct GitHubPermissions: Sendable, Hashable {
  public enum Repositories: Int, Sendable, Hashable, Comparable {
    case none, publicOnly, all

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  /// `repo` (public and private) or `public_repo`.
  public var repositories: Repositories
  /// `read:org`: list the user's organizations, including private memberships.
  public var organizations: Bool
  /// `workflow`: push changes to `.github/workflows`.
  public var workflows: Bool

  public init(repositories: Repositories, organizations: Bool, workflows: Bool) {
    self.repositories = repositories
    self.organizations = organizations
    self.workflows = workflows
  }

  /// What a git client normally needs, and the default in the chooser.
  public static let recommended = GitHubPermissions(
    repositories: .all, organizations: true, workflows: true)
  public static let none = GitHubPermissions(
    repositories: .none, organizations: false, workflows: false)

  /// Reads granted scopes, e.g. GitHub's `repo, read:org`, counting scopes that include others:
  /// `repo` includes `public_repo`, and `write:org` and `admin:org` include `read:org`.
  public init(scopes: some Sequence<String>) {
    let scopes = Set(scopes)
    repositories = scopes.contains("repo") ? .all : scopes.contains("public_repo") ? .publicOnly : .none
    organizations = !scopes.isDisjoint(with: ["read:org", "write:org", "admin:org"])
    workflows = scopes.contains("workflow")
  }

  /// The OAuth scopes to request.
  public var scopes: [String] {
    var scopes: [String] = []
    switch repositories {
    case .all: scopes.append("repo")
    case .publicOnly: scopes.append("public_repo")
    case .none: break
    }
    if organizations { scopes.append("read:org") }
    if workflows { scopes.append("workflow") }
    return scopes
  }

  /// Whether everything in `other` is granted here.
  public func includes(_ other: GitHubPermissions) -> Bool {
    repositories >= other.repositories && (organizations || !other.organizations)
      && (workflows || !other.workflows)
  }

  /// These permissions plus `other`'s.
  public func union(_ other: GitHubPermissions) -> GitHubPermissions {
    GitHubPermissions(
      repositories: max(repositories, other.repositories),
      organizations: organizations || other.organizations, workflows: workflows || other.workflows)
  }

  /// Splits a `scope` field or `X-OAuth-Scopes` header (`repo,read:org` or `repo, read:org`).
  static func parse(_ field: String) -> Set<String> {
    Set(field.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init))
  }
}
