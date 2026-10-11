import Foundation

public struct Branch: Sendable, Hashable, Identifiable {
  /// The full ref, e.g. `refs/heads/main` or `refs/remotes/origin/main`.
  public var refName: String
  /// The short name, e.g. `main` or `origin/main`.
  public var name: String
  public var isRemote: Bool
  public var isCurrent: Bool
  public var sha: String
  /// The upstream's short name, e.g. `origin/main`.
  public var upstream: String?
  public var ahead: Int
  public var behind: Int
  /// The upstream is configured but no longer exists.
  public var isUpstreamGone: Bool
  public var date: Date?
  public var subject: String
  /// Commits on this branch that HEAD doesn't have (`nil` when unknown, e.g. before the first
  /// commit).
  public var aheadOfHead: Int?
  /// Commits on HEAD that this branch doesn't have.
  public var behindHead: Int?

  public init(
    refName: String, name: String, isRemote: Bool, isCurrent: Bool = false, sha: String,
    upstream: String? = nil, ahead: Int = 0, behind: Int = 0, isUpstreamGone: Bool = false,
    date: Date? = nil, subject: String = "", aheadOfHead: Int? = nil, behindHead: Int? = nil
  ) {
    self.refName = refName
    self.name = name
    self.isRemote = isRemote
    self.isCurrent = isCurrent
    self.sha = sha
    self.upstream = upstream
    self.ahead = ahead
    self.behind = behind
    self.isUpstreamGone = isUpstreamGone
    self.date = date
    self.subject = subject
    self.aheadOfHead = aheadOfHead
    self.behindHead = behindHead
  }

  public var id: String { refName }

  /// For a remote branch: the remote (`origin`).
  public var remoteName: String? {
    guard isRemote, let slash = name.firstIndex(of: "/") else { return nil }
    return String(name[..<slash])
  }

  /// For a remote branch: the name without the remote (`main` for `origin/main`).
  public var localName: String {
    guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
    return String(name[name.index(after: slash)...])
  }
}

/// A working tree of the repository (`git worktree list`).
public struct Worktree: Sendable, Hashable, Identifiable {
  public var url: URL
  public var head: String?
  /// The checked-out branch's short name, or `nil` when detached.
  public var branch: String?
  public var isBare: Bool
  public var isLocked: Bool
  public var isPrunable: Bool
  /// The worktree this list was read from.
  public var isCurrent: Bool

  public init(
    url: URL, head: String? = nil, branch: String? = nil, isBare: Bool = false,
    isLocked: Bool = false, isPrunable: Bool = false, isCurrent: Bool = false
  ) {
    self.url = url
    self.head = head
    self.branch = branch
    self.isBare = isBare
    self.isLocked = isLocked
    self.isPrunable = isPrunable
    self.isCurrent = isCurrent
  }

  public var id: URL { url }
  public var name: String { url.lastPathComponent }
}

public struct Stash: Sendable, Hashable, Identifiable {
  /// `stash@{0}`.
  public var reference: String
  public var index: Int
  public var sha: String
  public var date: Date
  /// `WIP on main: …` or `On main: <message>`.
  public var message: String

  public init(reference: String, index: Int, sha: String, date: Date, message: String) {
    self.reference = reference
    self.index = index
    self.sha = sha
    self.date = date
    self.message = message
  }

  public var id: String { sha }
}
