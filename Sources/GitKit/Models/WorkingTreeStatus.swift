import Foundation

/// How a file differs on one side (index or working tree).
public enum ChangeKind: String, Sendable, Hashable {
  case added, modified, deleted, renamed, copied, typeChanged, untracked, conflicted

  /// The one-letter code git uses (`?` for untracked, `U` for conflicts).
  public var letter: String {
    switch self {
    case .added: "A"
    case .modified: "M"
    case .deleted: "D"
    case .renamed: "R"
    case .copied: "C"
    case .typeChanged: "T"
    case .untracked: "?"
    case .conflicted: "U"
    }
  }

  init?(code: Character) {
    switch code {
    case "A": self = .added
    case "M": self = .modified
    case "D": self = .deleted
    case "R": self = .renamed
    case "C": self = .copied
    case "T": self = .typeChanged
    case "U": self = .conflicted
    case "?": self = .untracked
    default: return nil
    }
  }
}

/// Where a change lives.
public enum ChangeArea: String, Sendable, Hashable {
  case staged, unstaged, conflicted
}

/// One changed path in `git status`.
public struct FileChange: Sendable, Hashable, Identifiable {
  public var path: String
  /// The source path of a rename or copy.
  public var originalPath: String?
  public var kind: ChangeKind
  public var area: ChangeArea
  public var isSubmodule: Bool

  public init(
    path: String, originalPath: String? = nil, kind: ChangeKind, area: ChangeArea,
    isSubmodule: Bool = false
  ) {
    self.path = path
    self.originalPath = originalPath
    self.kind = kind
    self.area = area
    self.isSubmodule = isSubmodule
  }

  public var id: String { "\(area.rawValue):\(path)" }
  public var fileName: String { (path as NSString).lastPathComponent }
  public var directory: String { (path as NSString).deletingLastPathComponent }
}

/// An operation git is in the middle of, which needs a continue or abort.
public enum RepositoryOperation: String, Sendable, Hashable {
  case merge, rebase, cherryPick, revert

  public var title: String {
    switch self {
    case .merge: "Merging"
    case .rebase: "Rebasing"
    case .cherryPick: "Cherry-picking"
    case .revert: "Reverting"
    }
  }
}

/// The parsed result of `git status --porcelain=v2 --branch`.
public struct WorkingTreeStatus: Sendable, Hashable {
  /// The current branch, or `nil` when HEAD is detached.
  public var branch: String?
  /// The commit HEAD points to, or `nil` before the first commit.
  public var headOID: String?
  /// The upstream branch, e.g. `origin/main`.
  public var upstream: String?
  public var ahead = 0
  public var behind = 0
  public var staged: [FileChange] = []
  public var unstaged: [FileChange] = []
  public var conflicted: [FileChange] = []
  public var operation: RepositoryOperation?

  public init() {}

  public var isClean: Bool { staged.isEmpty && unstaged.isEmpty && conflicted.isEmpty }
  public var changeCount: Int {
    Set(staged.map(\.path) + unstaged.map(\.path) + conflicted.map(\.path)).count
  }
  public var isDetached: Bool { branch == nil && headOID != nil }
  public var isUnborn: Bool { headOID == nil }
}

/// A light status for the sidebar.
public struct RepositorySummary: Sendable, Hashable {
  public var branch: String?
  public var headOID: String?
  public var changeCount: Int
  public var ahead: Int
  public var behind: Int
  public var hasUpstream: Bool

  public init(_ status: WorkingTreeStatus) {
    branch = status.branch
    headOID = status.headOID
    changeCount = status.changeCount
    ahead = status.ahead
    behind = status.behind
    hasUpstream = status.upstream != nil
  }

  public var branchLabel: String {
    if let branch { return branch }
    if let headOID { return String(headOID.prefix(7)) }
    return "No commits"
  }
}
