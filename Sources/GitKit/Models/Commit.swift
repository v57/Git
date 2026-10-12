import Foundation

/// A ref shown next to a commit (`%D` with `--decorate=full`).
public struct RefLabel: Sendable, Hashable {
  public enum Kind: Sendable, Hashable { case head, localBranch, remoteBranch, tag, other }

  public var name: String
  public var kind: Kind
  /// `true` for the branch HEAD points to (`HEAD -> refs/heads/main`).
  public var isCurrent: Bool

  public init(name: String, kind: Kind, isCurrent: Bool = false) {
    self.name = name
    self.kind = kind
    self.isCurrent = isCurrent
  }
}

public struct Commit: Sendable, Hashable, Identifiable {
  public var id: String
  public var parents: [String]
  public var authorName: String
  public var authorEmail: String
  public var authorDate: Date
  public var committerName: String
  public var committerEmail: String
  public var committerDate: Date
  public var refs: [RefLabel]
  public var subject: String
  public var body: String

  public init(
    id: String, parents: [String], authorName: String, authorEmail: String, authorDate: Date,
    committerName: String, committerEmail: String, committerDate: Date, refs: [RefLabel] = [],
    subject: String, body: String = ""
  ) {
    self.id = id
    self.parents = parents
    self.authorName = authorName
    self.authorEmail = authorEmail
    self.authorDate = authorDate
    self.committerName = committerName
    self.committerEmail = committerEmail
    self.committerDate = committerDate
    self.refs = refs
    self.subject = subject
    self.body = body
  }

  public var shortID: String { String(id.prefix(7)) }
  public var isMerge: Bool { parents.count > 1 }
  /// Subject and body as one message.
  public var message: String { body.isEmpty ? subject : "\(subject)\n\n\(body)" }

  /// `commits` newest first, when they can be squashed into one: two or more, no merges, and
  /// each one's parent is the next. Throws a `GitError` that says why not.
  public static func squashRun(_ commits: [Commit]) throws -> [Commit] {
    guard commits.count > 1 else { throw GitError(message: "Select two or more commits to squash.") }
    guard !commits.contains(where: \.isMerge) else {
      throw GitError(message: "Merge commits can't be squashed.")
    }
    let byID = Dictionary(commits.map { ($0.id, $0) }) { first, _ in first }
    let parents = Set(commits.compactMap(\.parents.first))
    // The newest is no other commit's parent; from it, every parent must be one of the commits.
    var run = commits.first { !parents.contains($0.id) }.map { [$0] } ?? []
    while run.count < byID.count, let parent = run.last?.parents.first, let next = byID[parent] {
      run.append(next)
    }
    guard run.count == byID.count else {
      throw GitError(message: "Only commits that follow one another can be squashed.")
    }
    return run
  }
}

extension GitError {
  static let squashOffHead = GitError(
    message: "Only commits on the current branch can be squashed.")
}

/// A path changed by a commit.
public struct CommitFile: Sendable, Hashable, Identifiable {
  public var path: String
  public var originalPath: String?
  public var kind: ChangeKind
  /// Lines added and removed, when known.
  public var lines: LineCounts?

  public init(
    path: String, originalPath: String? = nil, kind: ChangeKind, lines: LineCounts? = nil
  ) {
    self.path = path
    self.originalPath = originalPath
    self.kind = kind
    self.lines = lines
  }

  public var id: String { path }
  public var fileName: String { (path as NSString).lastPathComponent }
  public var directory: String { (path as NSString).deletingLastPathComponent }
}

/// Which commits `log` returns.
public struct LogQuery: Sendable, Hashable {
  /// A revision (branch, sha); `nil` means HEAD.
  public var revision: String?
  /// Every branch, remote-tracking branch and tag instead of only `revision`.
  public var allBranches: Bool
  /// Only commits that touch this path.
  public var path: String?
  /// Text to look for in `searchField` (case-insensitive).
  public var search: String?
  public var searchField: SearchField

  public enum SearchField: String, Sendable, Hashable, CaseIterable {
    /// The message, the author or a sha prefix.
    case any
    case message, author, sha
  }

  public init(
    revision: String? = nil, allBranches: Bool = false, path: String? = nil,
    search: String? = nil, searchField: SearchField = .message
  ) {
    self.revision = revision
    self.allBranches = allBranches
    self.path = path
    self.search = search
    self.searchField = searchField
  }

  /// Whether the commits form a graph: not filtered by a search or a path.
  public var showsGraph: Bool { search == nil && path == nil }
}
