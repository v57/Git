import AppKit
import GitKit
import SwiftUI

/// A unified diff with line numbers, syntax colors and line selection.
///
/// Click a line to select or deselect it, drag to select a range, shift-click to extend from the
/// last clicked line, and click a hunk header to select the whole hunk. ⌘C copies the selected
/// lines. With `changesOnly`, only added and removed lines can be selected (for staging).
struct DiffView<HunkActions: View>: View {
  let content: LoadedDiff
  @Binding var selection: Set<Int>
  var changesOnly = true
  @ViewBuilder var hunkActions: (DiffHunk) -> HunkActions

  @State private var anchor: Int?
  @State private var drag: DragState?
  @State private var showsLargeDiff = false
  @FocusState private var isFocused: Bool

  private struct DragState {
    var startRow: Int
    var selecting: Bool
    var baseline: Set<Int>
  }

  static var largeDiffLines: Int { 20_000 }
  private static var font: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
  private static var characterWidth: CGFloat {
    ("M" as NSString).size(withAttributes: [.font: font]).width
  }

  private var numberWidth: CGFloat { CGFloat(content.numberDigits) * Self.characterWidth + 12 }
  private var gutterWidth: CGFloat { numberWidth * 2 + 20 }

  var body: some View {
    if content.diff.lineCount > Self.largeDiffLines && !showsLargeDiff {
      ContentUnavailableView {
        Label("Large Diff", systemImage: "doc.text.magnifyingglass")
      } description: {
        Text("\(content.diff.lineCount.formatted()) lines changed.")
      } actions: {
        Button("Show Diff") { showsLargeDiff = true }
      }
    } else {
      GeometryReader { proxy in
        ScrollView([.vertical, .horizontal]) {
          let width = max(
            proxy.size.width,
            gutterWidth + CGFloat(content.maxColumns) * Self.characterWidth + 24)
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(content.rows) { row in
              rowView(row, width: width)
            }
          }
          .frame(width: width, alignment: .topLeading)
          .contentShape(Rectangle())
          .gesture(selectionGesture)
        }
      }
      .background(Color(nsColor: .textBackgroundColor))
      .focusable()
      .focusEffectDisabled()
      .focused($isFocused)
      .onCopyCommand { copyItems() }
      .onKeyPress(.escape) {
        selection = []
        return .handled
      }
      .contextMenu {
        Button("Copy Selected Lines") { copy() }
          .disabled(selection.isEmpty)
        Button("Clear Selection") { selection = [] }
          .disabled(selection.isEmpty)
      }
    }
  }

  // MARK: Rows

  @ViewBuilder
  private func rowView(_ row: LoadedDiff.Row, width: CGFloat) -> some View {
    switch row {
    case .hunk(let hunk):
      HStack(spacing: 8) {
        Text(hunk.header)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .padding(.leading, 8)
        Spacer(minLength: 8)
        hunkActions(hunk)
          .controlSize(.small)
          .buttonStyle(.bordered)
          .padding(.trailing, 8)
      }
      .frame(width: width, height: LoadedDiff.hunkHeight, alignment: .leading)
      .background(Color.secondary.opacity(0.1))
    case .line(let line, _):
      let isSelected = selection.contains(line.id)
      HStack(spacing: 0) {
        Text(line.oldLine.map(String.init) ?? "")
          .frame(width: numberWidth, alignment: .trailing)
        Text(line.newLine.map(String.init) ?? "")
          .frame(width: numberWidth, alignment: .trailing)
        Text(marker(line))
          .frame(width: 20)
      }
      .font(.system(size: 11, design: .monospaced))
      .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
      .frame(width: gutterWidth, height: LoadedDiff.lineHeight)
      .background(isSelected ? Color.accentColor : gutterColor(line))
      .overlay(alignment: .leading) {
        Text(content.rendered[line.id] ?? DiffHighlighter.plain(line.text))
          .font(Font(Self.font))
          .lineLimit(1)
          .fixedSize()
          .offset(x: gutterWidth + 4)
      }
      .frame(width: width, height: LoadedDiff.lineHeight, alignment: .leading)
      .background(background(line, isSelected: isSelected))
    }
  }

  private func marker(_ line: DiffLine) -> String {
    switch line.kind {
    case .added: "+"
    case .removed: "−"
    case .context: line.noNewlineAtEnd ? "⏎" : ""
    }
  }

  private func background(_ line: DiffLine, isSelected: Bool) -> Color {
    if isSelected { return Color.accentColor.opacity(0.22) }
    switch line.kind {
    case .added: return Color.green.opacity(0.13)
    case .removed: return Color.red.opacity(0.13)
    case .context: return .clear
    }
  }

  private func gutterColor(_ line: DiffLine) -> Color {
    switch line.kind {
    case .added: Color.green.opacity(0.2)
    case .removed: Color.red.opacity(0.2)
    case .context: Color.secondary.opacity(0.05)
    }
  }

  // MARK: Selection

  private func isSelectable(_ line: DiffLine) -> Bool { !changesOnly || line.isChange }

  private func selectableIDs(rows range: ClosedRange<Int>) -> [Int] {
    content.rows[range].flatMap { row -> [Int] in
      switch row {
      case .line(let line, _): isSelectable(line) ? [line.id] : []
      case .hunk: []
      }
    }
  }

  private var selectionGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        isFocused = true
        guard let current = content.rowIndex(at: value.location.y) else { return }
        if drag == nil {
          guard let start = content.rowIndex(at: value.startLocation.y) else { return }
          begin(at: start, extend: NSEvent.modifierFlags.contains(.shift))
        }
        guard let drag else { return }
        let range = min(drag.startRow, current)...max(drag.startRow, current)
        guard range.count > 1 else { return }
        let ids = Set(selectableIDs(rows: range))
        selection = drag.selecting ? drag.baseline.union(ids) : drag.baseline.subtracting(ids)
      }
      .onEnded { _ in drag = nil }
  }

  private func begin(at row: Int, extend: Bool) {
    switch content.rows[row] {
    case .hunk(let hunk):
      // Toggle every selectable line in the hunk.
      let ids = Set(hunk.lines.filter(isSelectable).map(\.id))
      selection = ids.isSubset(of: selection) ? selection.subtracting(ids) : selection.union(ids)
      drag = DragState(startRow: row, selecting: true, baseline: selection)
    case .line(let line, _):
      if extend, let anchor, let anchorRow = content.rows.firstIndex(where: { $0.id == anchor }) {
        let ids = selectableIDs(rows: min(anchorRow, row)...max(anchorRow, row))
        selection.formUnion(ids)
        drag = DragState(startRow: row, selecting: true, baseline: selection)
        return
      }
      guard isSelectable(line) else {
        drag = DragState(startRow: row, selecting: true, baseline: selection)
        return
      }
      let selecting = !selection.contains(line.id)
      if selecting { selection.insert(line.id) } else { selection.remove(line.id) }
      anchor = line.id
      drag = DragState(startRow: row, selecting: selecting, baseline: selection)
    }
  }

  // MARK: Copy

  private var selectedText: String {
    content.diff.lines.filter { selection.contains($0.id) }.map(\.text).joined(separator: "\n")
  }

  private func copyItems() -> [NSItemProvider] {
    guard !selection.isEmpty else { return [] }
    return [NSItemProvider(object: selectedText as NSString)]
  }

  private func copy() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(selectedText, forType: .string)
  }
}

extension DiffView where HunkActions == EmptyView {
  init(content: LoadedDiff, selection: Binding<Set<Int>>, changesOnly: Bool = false) {
    self.init(content: content, selection: selection, changesOnly: changesOnly) { _ in
      EmptyView()
    }
  }
}

/// Placeholder content for diffs that have no lines to show.
struct DiffPlaceholder: View {
  let diff: FileDiff

  var body: some View {
    if diff.isBinary {
      ContentUnavailableView("Binary File", systemImage: "doc.zipper", description: Text(diff.path))
    } else if diff.isRename && diff.hunks.isEmpty {
      ContentUnavailableView(
        "Renamed", systemImage: "arrow.right",
        description: Text("\(diff.oldPath ?? "") → \(diff.newPath ?? "")"))
    } else if diff.isModeChangeOnly {
      ContentUnavailableView(
        "Mode Changed", systemImage: "lock.shield",
        description: Text("\(diff.oldMode ?? "") → \(diff.newMode ?? "")"))
    } else {
      ContentUnavailableView("No Changes", systemImage: "equal", description: Text(diff.path))
    }
  }
}
