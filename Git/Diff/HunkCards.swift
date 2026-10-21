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
    let lines = content.lines[hunk.id]
    let header = hunk.section.isEmpty ? (content.diff.isNewFile ? "New file" : "") : hunk.section
    let range = "@@ -\(Self.range(hunk.oldStart, hunk.oldCount)) +\(Self.range(hunk.newStart, hunk.newCount)) @@"
    switch mode {
    case .readOnly:
      HunkCard(header: header, range: range, lines: lines, overflow: .scroll)
    case .unstaged(let stage, let discard):
      HunkCard(
        header: header, range: range, lines: lines, selection: kitSelection(hunk),
        stage: { chosen in stage(Set(chosen.map(\.id))) }, overflow: .scroll
      )
      .kitContextMenu {
        Button("Discard Hunk…", systemImage: "trash", role: .destructive) { discard(PatchBuilder.lines(in: hunk)) }
      }
    case .staged(let unstage):
      HunkCard(
        header: header, range: range, lines: lines, isStaged: true, summary: summary(hunk),
        selection: kitSelection(hunk), unstage: { unstage(PatchBuilder.lines(in: hunk)) },
        unstageLines: { chosen in unstage(Set(chosen.map(\.id))) }, overflow: .scroll)
    }
  }

  /// "14" for one line, "14,6" for more, as in the hunk header.
  private static func range(_ start: Int, _ count: Int) -> String {
    count == 1 ? "\(start)" : "\(start),\(count)"
  }

  /// The selection as the card sees it: the kit's lines carry GitKit's ids, so it's the same set, but the card's
  /// changes only touch its own lines (a drag in one hunk keeps the lines chosen in the others).
  private func kitSelection(_ hunk: DiffHunk) -> Binding<Set<Int>> {
    // A hunk's line ids are consecutive.
    let ids = (hunk.lines.first?.id ?? 0)..<((hunk.lines.last?.id ?? -1) + 1)
    return Binding(
      get: { selection },
      set: { kit in selection = selection.filter { !ids.contains($0) }.union(kit.filter { ids.contains($0) }) })
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
