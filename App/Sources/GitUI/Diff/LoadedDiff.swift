import ComponentKit
import Foundation
import GitKit

/// A diff ready to show: the parsed diff and, for each hunk, the kit's lines with their syntax colors.
nonisolated public struct LoadedDiff: Sendable {
  public let target: DiffTarget
  public let diff: FileDiff
  /// Each hunk's lines (by hunk id), with GitKit's line ids, so selections need no mapping.
  public let lines: [[ComponentKit.DiffLine]]

  /// Loads the diff for `target` and highlights it with the file contents on both sides. A diff longer than
  /// `DiffHighlighter.maxLines` stays plain: coloring a million lines would take half a minute.
  @concurrent public static func load(
    _ target: DiffTarget, repository: Repository, isDark: Bool, ignoreWhitespace: Bool = false
  ) async throws -> LoadedDiff? {
    try await load(
      target, isDark: isDark,
      diff: { try await repository.diff(target, ignoreWhitespace: ignoreWhitespace) },
      contents: { await repository.contents(of: $0, at: $1) })
  }

  /// Loads the diff from wherever `diff` and `contents` read it (in the iOS app, a repository on the device, which
  /// GitEngine reads, or one on a Mac).
  @concurrent public static func load(
    _ target: DiffTarget, isDark: Bool, diff: @Sendable () async throws -> FileDiff?,
    contents: @Sendable (String, FileRevision) async -> Data?
  ) async throws -> LoadedDiff? {
    guard let diff = try await diff() else { return nil }
    var rendered: [Int: AttributedString] = [:]
    if !diff.isBinary, diff.lineCount <= DiffHighlighter.maxLines, DiffHighlighter.mayHighlight(diff.path) {
      var oldText: String?
      var newText: String?
      let oldPath = diff.oldPath ?? target.path
      let newPath = diff.newPath ?? target.path
      let sides: (FileRevision?, FileRevision?)
      switch target {
      case .unstaged(_, let untracked):
        sides = (untracked ? nil : .index, .workingTree)
      case .staged:
        sides = (.commit("HEAD"), .index)
      case .commit(let sha, let parent, _, _):
        sides = (parent.map(FileRevision.commit), .commit(sha))
      }
      if !diff.isNewFile, let revision = sides.0 {
        oldText = await contents(oldPath, revision).flatMap(Self.text)
      }
      if !diff.isDeletedFile, let revision = sides.1 {
        newText = await contents(newPath, revision).flatMap(Self.text)
      }
      rendered = DiffHighlighter.render(diff, oldText: oldText, newText: newText, isDark: isDark)
    }
    let lines = diff.hunks.map { hunk in
      hunk.lines.map { line in
        let kind: ComponentKit.DiffLine.Kind =
          switch line.kind {
          case .added: .added
          case .removed: .removed
          case .context: .context
          }
        return if let text = rendered[line.id] {
          ComponentKit.DiffLine(kind, old: line.oldLine, new: line.newLine, text: text, id: line.id)
        } else {
          ComponentKit.DiffLine(
            kind, old: line.oldLine, new: line.newLine, text: DiffHighlighter.display(line.text), id: line.id)
        }
      }
    }
    return LoadedDiff(target: target, diff: diff, lines: lines)
  }

  private static func text(_ data: Data) -> String? {
    data.count <= DiffHighlighter.maxFileSize ? String(data: data, encoding: .utf8) : nil
  }
}
