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

  public init(
    refName: String, name: String, isRemote: Bool, isCurrent: Bool = false, sha: String,
    upstream: String? = nil, ahead: Int = 0, behind: Int = 0, isUpstreamGone: Bool = false,
    date: Date? = nil, subject: String = ""
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
