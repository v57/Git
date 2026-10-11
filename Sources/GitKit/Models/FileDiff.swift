import Foundation

/// One line of a unified diff.
public struct DiffLine: Sendable, Hashable, Identifiable {
  public enum Kind: Sendable, Hashable { case context, added, removed }

  /// Position in the file's diff (counts across hunks), used for selection.
  public var id: Int
  public var kind: Kind
  /// The line without its `+`/`-`/space prefix or newline. A trailing `\r` is kept.
  public var text: String
  public var oldLine: Int?
  public var newLine: Int?
  /// Followed by `\ No newline at end of file`.
  public var noNewlineAtEnd: Bool

  public init(
    id: Int, kind: Kind, text: String, oldLine: Int?, newLine: Int?, noNewlineAtEnd: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.text = text
    self.oldLine = oldLine
    self.newLine = newLine
    self.noNewlineAtEnd = noNewlineAtEnd
  }

  public var isChange: Bool { kind != .context }

  var prefix: Character {
    switch kind {
    case .context: " "
    case .added: "+"
    case .removed: "-"
    }
  }
}

public struct DiffHunk: Sendable, Hashable, Identifiable {
  public var id: Int
  public var oldStart: Int
  public var oldCount: Int
  public var newStart: Int
  public var newCount: Int
  /// The function context after the second `@@`.
  public var section: String
  public var lines: [DiffLine]

  public init(
    id: Int, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String = "",
    lines: [DiffLine]
  ) {
    self.id = id
    self.oldStart = oldStart
    self.oldCount = oldCount
    self.newStart = newStart
    self.newCount = newCount
    self.section = section
    self.lines = lines
  }

  public var header: String {
    "@@ -\(Self.range(oldStart, oldCount)) +\(Self.range(newStart, newCount)) @@"
      + (section.isEmpty ? "" : " \(section)")
  }

  static func range(_ start: Int, _ count: Int) -> String {
    count == 1 ? "\(start)" : "\(start),\(count)"
  }

  public var changedLineIDs: [Int] { lines.filter(\.isChange).map(\.id) }
}

/// One file's diff.
public struct FileDiff: Sendable, Hashable {
  /// `nil` for a new file.
  public var oldPath: String?
  /// `nil` for a deleted file.
  public var newPath: String?
  public var oldMode: String?
  public var newMode: String?
  public var isBinary: Bool
  public var isRename: Bool
  public var isCopy: Bool
  public var similarity: Int?
  public var hunks: [DiffHunk]
  /// Some bytes were not valid UTF-8 and were replaced; line patches would corrupt the file.
  public var hasInvalidUTF8: Bool

  public init(
    oldPath: String?, newPath: String?, oldMode: String? = nil, newMode: String? = nil,
    isBinary: Bool = false, isRename: Bool = false, isCopy: Bool = false, similarity: Int? = nil,
    hunks: [DiffHunk] = [], hasInvalidUTF8: Bool = false
  ) {
    self.oldPath = oldPath
    self.newPath = newPath
    self.oldMode = oldMode
    self.newMode = newMode
    self.isBinary = isBinary
    self.isRename = isRename
    self.isCopy = isCopy
    self.similarity = similarity
    self.hunks = hunks
    self.hasInvalidUTF8 = hasInvalidUTF8
  }

  public var path: String { newPath ?? oldPath ?? "" }
  public var isNewFile: Bool { oldPath == nil }
  public var isDeletedFile: Bool { newPath == nil }
  public var isModeChangeOnly: Bool { hunks.isEmpty && oldMode != nil && oldMode != newMode }
  public var lines: [DiffLine] { hunks.flatMap(\.lines) }
  public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
  public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .added } } }
  public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .removed } } }

  /// Whether individual lines can be staged, unstaged or discarded.
  public var supportsLineSelection: Bool {
    !isBinary && !isRename && !isCopy && !hasInvalidUTF8 && !hunks.isEmpty
  }
}

/// What a diff compares.
public enum DiffTarget: Sendable, Hashable {
  /// Working tree against the index. `untracked` files are diffed against `/dev/null`.
  case unstaged(path: String, untracked: Bool)
  /// Index against HEAD.
  case staged(path: String, originalPath: String?)
  /// A commit against its first parent (or the empty tree for a root commit).
  case commit(sha: String, parent: String?, path: String, originalPath: String?)

  public var path: String {
    switch self {
    case .unstaged(let path, _), .staged(let path, _), .commit(_, _, let path, _): path
    }
  }
}

/// Where file contents come from.
public enum FileRevision: Sendable, Hashable {
  case workingTree
  case index
  case commit(String)
}
