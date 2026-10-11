import Foundation
import GitKit
import SwiftUI

/// A diff ready to show: the parsed diff, rendered lines and the row layout.
nonisolated struct LoadedDiff: Sendable {
  enum Row: Sendable, Identifiable {
    case hunk(DiffHunk)
    case line(DiffLine, hunkID: Int)

    var id: Int {
      switch self {
      case .hunk(let hunk): -1 - hunk.id
      case .line(let line, _): line.id
      }
    }
  }

  static let lineHeight: CGFloat = 21
  static let hunkHeight: CGFloat = 34

  let target: DiffTarget
  let diff: FileDiff
  let rendered: [Int: AttributedString]
  let rows: [Row]
  /// The y offset of each row's top, plus the total height at the end.
  let offsets: [CGFloat]
  /// The longest line, in characters (tabs expanded).
  let maxColumns: Int
  let numberDigits: Int
  /// Space above every hunk but the first, for hunks drawn as separate cards.
  let hunkGap: CGFloat
  /// The last line of each hunk, which closes its card.
  let lastLines: Set<Int>

  init(target: DiffTarget, diff: FileDiff, rendered: [Int: AttributedString], hunkGap: CGFloat = 0) {
    self.target = target
    self.diff = diff
    self.rendered = rendered
    self.hunkGap = hunkGap
    self.lastLines = Set(diff.hunks.compactMap { $0.lines.last?.id })
    var rows: [Row] = []
    var offsets: [CGFloat] = []
    var y: CGFloat = 0
    var maxColumns = 0
    var maxNumber = 0
    for (index, hunk) in diff.hunks.enumerated() {
      rows.append(.hunk(hunk))
      offsets.append(y)
      y += Self.hunkHeight + (index > 0 ? hunkGap : 0)
      for line in hunk.lines {
        rows.append(.line(line, hunkID: hunk.id))
        offsets.append(y)
        y += Self.lineHeight
        maxColumns = max(maxColumns, DiffHighlighter.display(line.text).count)
        maxNumber = max(maxNumber, line.oldLine ?? 0, line.newLine ?? 0)
      }
    }
    offsets.append(y)
    self.rows = rows
    self.offsets = offsets
    self.maxColumns = maxColumns
    self.numberDigits = max(String(maxNumber).count, 3)
  }

  var totalHeight: CGFloat { offsets.last ?? 0 }

  /// The same diff laid out with `gap` between hunks.
  func spaced(by gap: CGFloat) -> LoadedDiff {
    LoadedDiff(target: target, diff: diff, rendered: rendered, hunkGap: gap)
  }

  /// The row at `y`, clamped to the rows.
  func rowIndex(at y: CGFloat) -> Int? {
    guard !rows.isEmpty else { return nil }
    var low = 0
    var high = rows.count - 1
    while low < high {
      let mid = (low + high + 1) / 2
      if offsets[mid] <= y { low = mid } else { high = mid - 1 }
    }
    return low
  }

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
