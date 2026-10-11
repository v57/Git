import Foundation

/// Builds patches that apply only some lines of a diff, for staging, unstaging and discarding
/// individual lines or hunks (the git-gui / GitHub Desktop approach).
///
/// - Forward (stage lines from the unstaged diff, `git apply --cached`): unselected additions are
///   dropped and unselected removals become context, so the old side (the index) is unchanged.
/// - Reverse (unstage from the staged diff with `apply --cached -R`, or discard from the unstaged
///   diff with `apply -R`): unselected removals are dropped and unselected additions become
///   context, so the new side (what the patch is applied to) is unchanged.
public enum PatchBuilder {
  public enum Direction: Sendable { case forward, reverse }

  /// A patch containing only the `selected` changed lines, or `nil` when none of them are
  /// changes.
  public static func patch(for diff: FileDiff, selecting selected: Set<Int>, direction: Direction)
    -> String?
  {
    var hunks: [String] = []
    var hasContext = false
    var keptAllChanges = true
    // Lines added minus lines removed by the hunks emitted so far.
    var delta = 0

    for hunk in diff.hunks {
      var body: [String] = []
      var oldCount = 0
      var newCount = 0
      var changed = false

      for (line, output) in transform(hunk.lines, selected: selected, direction: direction) {
        if output == " " || output == "-" { oldCount += 1 }
        if output == " " || output == "+" { newCount += 1 }
        if output == " " { hasContext = true } else { changed = true }
        body.append("\(output)\(line.text)")
        if line.noNewlineAtEnd { body.append("\\ No newline at end of file") }
      }
      if hunk.lines.contains(where: { $0.isChange && !selected.contains($0.id) }) {
        keptAllChanges = false
      }
      // A hunk with nothing selected is left out and shifts nothing.
      guard changed else { continue }

      let header: String
      switch direction {
      case .forward:
        // The old side is untouched; place the new side after earlier hunks' changes.
        let oldFirst = hunk.oldCount == 0 ? hunk.oldStart + 1 : hunk.oldStart
        let newFirst = oldFirst + delta
        let newStart = newCount == 0 ? newFirst - 1 : newFirst
        header = "@@ -\(DiffHunk.range(hunk.oldStart, oldCount)) +\(DiffHunk.range(newStart, newCount)) @@"
      case .reverse:
        let newFirst = hunk.newCount == 0 ? hunk.newStart + 1 : hunk.newStart
        let oldFirst = newFirst - delta
        let oldStart = oldCount == 0 ? oldFirst - 1 : oldFirst
        header = "@@ -\(DiffHunk.range(oldStart, oldCount)) +\(DiffHunk.range(hunk.newStart, newCount)) @@"
      }
      delta += newCount - oldCount
      hunks.append(([header] + body).joined(separator: "\n"))
    }
    guard !hunks.isEmpty else { return nil }

    // A new or deleted file whose patch keeps context lines is now a plain modification.
    let keepsCreation = diff.isNewFile && (keptAllChanges || !hasContext)
    let keepsDeletion = diff.isDeletedFile && (keptAllChanges || !hasContext)
    let path = diff.path
    let oldPath = diff.oldPath ?? path
    let newPath = diff.newPath ?? path
    var header = ["diff --git a/\(oldPath) b/\(newPath)"]
    if keepsCreation {
      header.append("new file mode \(diff.newMode ?? "100644")")
      header.append("--- /dev/null")
      header.append("+++ b/\(newPath)")
    } else if keepsDeletion {
      header.append("deleted file mode \(diff.oldMode ?? "100644")")
      header.append("--- a/\(oldPath)")
      header.append("+++ /dev/null")
    } else {
      header.append("--- a/\(oldPath)")
      header.append("+++ b/\(newPath)")
    }
    return (header + hunks).joined(separator: "\n") + "\n"
  }

  /// Rewrites a hunk's lines as (line, prefix) pairs for the patch, block by block.
  ///
  /// Within a block of changes, unselected lines that become context keep their order on the side
  /// that stays intact, but the ones before the first selected line go before the block and the
  /// ones after the last selected line go after it. So replacing `a` with `A` out of
  /// `-a -b +A +B` gives `-a +A  b` (A, b) rather than `-a  b +A` (b, A).
  static func transform(_ lines: [DiffLine], selected: Set<Int>, direction: Direction)
    -> [(DiffLine, Character)]
  {
    var result: [(DiffLine, Character)] = []
    var index = 0
    while index < lines.count {
      guard lines[index].isChange else {
        result.append((lines[index], " "))
        index += 1
        continue
      }
      var end = index
      while end < lines.count, lines[end].isChange { end += 1 }
      let block = lines[index..<end]
      index = end

      // The side whose unselected lines turn into context; the other side's are dropped.
      let keptKind: DiffLine.Kind = direction == .forward ? .removed : .added
      let kept = block.filter { $0.kind == keptKind }
      let other = block.filter { $0.kind != keptKind && selected.contains($0.id) }
      let first = kept.firstIndex { selected.contains($0.id) }
      let last = kept.lastIndex { selected.contains($0.id) }
      let keptPrefix: Character = keptKind == .removed ? "-" : "+"
      let otherPrefix: Character = keptKind == .removed ? "+" : "-"

      var before: [(DiffLine, Character)] = []
      var middle: [(DiffLine, Character)] = []
      var after: [(DiffLine, Character)] = []
      for (position, line) in kept.enumerated() {
        let isSelected = selected.contains(line.id)
        if let first, let last, position >= first, position <= last {
          middle.append((line, isSelected ? keptPrefix : " "))
        } else if let last, position > last {
          after.append((line, " "))
        } else {
          before.append((line, " "))
        }
      }
      let others = other.map { ($0, otherPrefix) }
      // Removals come before additions, as in git's own output.
      if direction == .forward {
        result += before + middle + others + after
      } else {
        result += before + others + middle + after
      }
    }
    return result
  }

  /// Every changed line in `hunk`.
  public static func lines(in hunk: DiffHunk) -> Set<Int> { Set(hunk.changedLineIDs) }
}
