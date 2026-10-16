import Foundation
import GitKit

/// A diff ready to show: the parsed diff and its lines with their syntax colors.
nonisolated struct LoadedDiff: Sendable {
  let target: DiffTarget
  let diff: FileDiff
  let rendered: [Int: AttributedString]

  /// Loads the diff for `target` and highlights it with the file contents on both sides.
  @concurrent static func load(
    _ target: DiffTarget, repository: Repository, isDark: Bool, ignoreWhitespace: Bool = false
  ) async throws -> LoadedDiff? {
    guard let diff = try await repository.diff(target, ignoreWhitespace: ignoreWhitespace)
    else { return nil }
    var oldText: String?
    var newText: String?
    if !diff.isBinary, DiffHighlighter.mayHighlight(diff.path) {
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
        oldText = await repository.contents(of: oldPath, at: revision).flatMap(Self.text)
      }
      if !diff.isDeletedFile, let revision = sides.1 {
        newText = await repository.contents(of: newPath, at: revision).flatMap(Self.text)
      }
    }
    let rendered = DiffHighlighter.render(diff, oldText: oldText, newText: newText, isDark: isDark)
    return LoadedDiff(target: target, diff: diff, rendered: rendered)
  }

  private static func text(_ data: Data) -> String? {
    data.count <= DiffHighlighter.maxFileSize ? String(data: data, encoding: .utf8) : nil
  }
}
