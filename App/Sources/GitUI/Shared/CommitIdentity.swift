import GitKit
import VaultKit

/// Who commits in a repository the apps show, decided right before an action that can make a commit
/// (`RepositorySession.identity`): the repository's own `user.name`/`user.email` win, then the account's name and email
/// (`VaultProfile`, handed to git as `GIT_AUTHOR_*`, never written to the user's git config), then git's own settings.
/// Only when none of them names anyone, and the action always makes a commit, does `ask` show the Your Name sheet.
@MainActor
public enum CommitIdentity {
  public enum Answer: Equatable, Sendable {
    /// git's settings name who commits (or the action may make no commit).
    case gitSettings
    /// The account's name and email.
    case profile(VaultProfile)

    public var profile: VaultProfile? {
      if case .profile(let profile) = self { profile } else { nil }
    }
  }

  /// Who commits `activity`, given what git's settings name (`configured`); nil when the user cancelled the sheet.
  public static func answer(
    for activity: RepositorySession.Activity, configured: Repository.IdentityConfiguration, profile: VaultProfile,
    ask: () async -> VaultProfile?
  ) async -> Answer? {
    if configured.repository { return .gitSettings }
    if profile.isComplete { return .profile(profile) }
    if configured.any || !activity.alwaysCommits { return .gitSettings }
    return await ask().map(Answer.profile)
  }

  /// The environment git runs `activity` with in `repository`; nil when the user cancelled the sheet.
  public static func environment(
    for activity: RepositorySession.Activity, in repository: Repository, profile: VaultProfile,
    ask: () async -> VaultProfile?
  ) async -> [String: String]? {
    let configured = await repository.identityConfiguration()
    return await answer(for: activity, configured: configured, profile: profile, ask: ask)
      .map { $0.profile?.gitEnvironment ?? [:] }
  }

  /// Why the sheet asks, under its title.
  public static let reason = "Git puts them on the commits you make."
}
