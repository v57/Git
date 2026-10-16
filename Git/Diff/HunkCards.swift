import ComponentKit
import GitKit
import SwiftUI

/// A diff as the kit's hunk cards, headed by the function each hunk is in, on the panel ground.
/// Unstaged hunks stage a line (the + on hover), the selected lines or the whole hunk; staged
/// hunks fold to their header with Unstage, and unstage a line or the selected lines the same way.
/// The cards draw their lines lazily and scroll long lines sideways, so any diff fits.
struct HunkCards: View {
  enum Mode {
    /// A commit's diff: nothing to stage.
    case readOnly
    /// Unstaged changes: lines and hunks stage.
    case unstaged(stage: (Set<Int>) -> Void, discard: (Set<Int>) -> Void)
    /// Staged changes: lines and hunks unstage.
    case staged(unstage: (Set<Int>) -> Void)
  }

  let content: LoadedDiff
  var mode: Mode = .readOnly
  /// Selected lines, by GitKit's line ids.
  @Binding var selection: Set<Int>

  var body: some View {
    LazyVStack(spacing: 10) {
      ForEach(content.diff.hunks) { hunk in card(hunk) }
    }
  }

  @ViewBuilder
  private func card(_ hunk: DiffHunk) -> some View {
    let lines = hunk.lines.map(kitLine)
    let header = hunk.section.isEmpty ? (content.diff.isNewFile ? "New file" : "") : hunk.section
    let range = "@@ -\(Self.range(hunk.oldStart, hunk.oldCount)) +\(Self.range(hunk.newStart, hunk.newCount)) @@"
    switch mode {
    case .readOnly:
      HunkCard(header: header, range: range, lines: lines, overflow: .scroll)
    case .unstaged(let stage, let discard):
      HunkCard(
        header: header, range: range, lines: lines, selection: kitSelection(hunk),
        stage: { chosen in stage(gitIDs(chosen, in: hunk)) }, overflow: .scroll
      )
      .contextMenu {
        Button("Discard Hunk…", role: .destructive) { discard(PatchBuilder.lines(in: hunk)) }
      }
    case .staged(let unstage):
      HunkCard(
        header: header, range: range, lines: lines, isStaged: true, summary: summary(hunk),
        selection: kitSelection(hunk), unstage: { unstage(PatchBuilder.lines(in: hunk)) },
        unstageLines: { chosen in unstage(gitIDs(chosen, in: hunk)) }, overflow: .scroll)
    }
  }

  /// "14" for one line, "14,6" for more, as in the hunk header.
  private static func range(_ start: Int, _ count: Int) -> String {
    count == 1 ? "\(start)" : "\(start),\(count)"
  }

  /// The kit's line for a GitKit line, with its syntax colors.
  private func kitLine(_ line: GitKit.DiffLine) -> ComponentKit.DiffLine {
    let kind: ComponentKit.DiffLine.Kind =
      switch line.kind {
      case .added: .added
      case .removed: .removed
      case .context: .context
      }
    return ComponentKit.DiffLine(
      kind, old: line.oldLine, new: line.newLine,
      text: content.rendered[line.id] ?? AttributedString(DiffHighlighter.display(line.text)))
  }

  /// The kit's line ids (old and new numbers) to GitKit's.
  private func ids(_ hunk: DiffHunk) -> [String: Int] {
    Dictionary(
      hunk.lines.map { ("\($0.oldLine ?? -1):\($0.newLine ?? -1)", $0.id) }, uniquingKeysWith: { a, _ in a })
  }

  /// GitKit's line ids for the kit's lines.
  private func gitIDs(_ lines: [ComponentKit.DiffLine], in hunk: DiffHunk) -> Set<Int> {
    let ids = ids(hunk)
    return Set(lines.compactMap { ids[$0.id] })
  }

  private func kitSelection(_ hunk: DiffHunk) -> Binding<Set<String>> {
    let ids = ids(hunk)
    let inHunk = Set(ids.values)
    return Binding(
      get: { Set(ids.filter { selection.contains($0.value) }.keys) },
      set: { kit in selection = selection.subtracting(inHunk).union(kit.compactMap { ids[$0] }) })
  }

  /// "3 lines added, 1 removed", for a folded staged hunk.
  private func summary(_ hunk: DiffHunk) -> String {
    let added = hunk.lines.count { $0.kind == .added }
    let removed = hunk.lines.count { $0.kind == .removed }
    var parts: [String] = []
    if added > 0 { parts.append(added == 1 ? "1 line added" : "\(added) lines added") }
    if removed > 0 { parts.append(added > 0 ? "\(removed) removed" : removed == 1 ? "1 line removed" : "\(removed) lines removed") }
    return parts.joined(separator: ", ") + (hunk.section.isEmpty ? "" : " in \(hunk.section)")
  }
}

/// Placeholder content for diffs that have no lines to show.
struct DiffPlaceholder: View {
  let diff: FileDiff

  var body: some View {
    if diff.isBinary {
      EmptyState(systemImage: "doc.zipper", title: "Binary File", message: diff.path)
    } else if diff.isRename && diff.hunks.isEmpty {
      EmptyState(systemImage: "arrow.right", title: "Renamed", message: "\(diff.oldPath ?? "") → \(diff.newPath ?? "")")
    } else if diff.isModeChangeOnly {
      EmptyState(systemImage: "lock.shield", title: "Mode Changed", message: "\(diff.oldMode ?? "") → \(diff.newMode ?? "")")
    } else {
      EmptyState(systemImage: "equal", title: "No Changes", message: diff.path)
    }
  }
}
