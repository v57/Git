import Foundation
import GitKit

/// One side of a file diff: its path, mode and contents, or nothing when the file doesn't exist on that side.
struct DiffSide {
  var path: String
  var mode: FileMode
  var data: Data
}

/// Builds GitKit's `FileDiff` the way `DiffParser` reads `git diff -U3` output: line IDs numbered across the file,
/// hunk headers with git's function context, `\ No newline at end of file` on the last line of a side.
enum DiffBuilder {
  static let context = 3

  /// git's binary check: a NUL byte in the first 8000 bytes.
  static func isBinary(_ data: Data) -> Bool {
    data.prefix(8000).contains(0)
  }

  /// The diff between two sides, or `nil` when they're the same.
  static func diff(old: DiffSide?, new: DiffSide?, similarity: Int? = nil) -> FileDiff? {
    guard old != nil || new != nil else { return nil }
    if let old, let new, old.data == new.data, old.mode == new.mode, old.path == new.path { return nil }
    var file = FileDiff(oldPath: old?.path, newPath: new?.path, oldMode: old?.mode.octal, newMode: new?.mode.octal)
    if let old, let new, old.path != new.path {
      file.isRename = true
      file.similarity = similarity
      // A pure rename has no `index` line, so no modes.
      if old.data == new.data, old.mode == new.mode {
        file.oldMode = nil
        file.newMode = nil
      }
    }
    let oldData = old?.data ?? Data()
    let newData = new?.data ?? Data()
    if oldData == newData { return file }
    if isBinary(oldData) || isBinary(newData) {
      file.isBinary = true
      return file
    }
    file.hasInvalidUTF8 = !isValidUTF8(oldData) || !isValidUTF8(newData)
    file.hunks = hunks(Lines(oldData), Lines(newData))
    return file
  }

  static func isValidUTF8(_ data: Data) -> Bool {
    String(data: data, encoding: .utf8) != nil
  }

  /// Lines added and removed, or `nil`s for binary files, as `--numstat` counts them.
  static func lineCounts(old: Data?, new: Data?) -> LineCounts {
    let oldData = old ?? Data()
    let newData = new ?? Data()
    if isBinary(oldData) || isBinary(newData) { return LineCounts(added: nil, removed: nil) }
    if oldData == newData { return LineCounts(added: 0, removed: 0) }
    let changes = LineDiff.changes(Lines(oldData), Lines(newData))
    return LineCounts(
      added: changes.reduce(0) { $0 + $1.newCount }, removed: changes.reduce(0) { $0 + $1.oldCount })
  }

  static func hunks(_ old: Lines, _ new: Lines) -> [DiffHunk] {
    let changes = LineDiff.changes(old, new)
    var hunks: [DiffHunk] = []
    var lineID = 0
    var index = 0
    while index < changes.count {
      // Changes no more than two contexts apart share a hunk.
      var last = index
      while last + 1 < changes.count,
        changes[last + 1].oldStart - (changes[last].oldStart + changes[last].oldCount) <= 2 * context
      {
        last += 1
      }
      let first = changes[index]
      let lead = min(context, first.oldStart, first.newStart)
      let end = changes[last]
      let trail = min(
        context, old.count - (end.oldStart + end.oldCount), new.count - (end.newStart + end.newCount))
      let oldStart = first.oldStart - lead
      let newStart = first.newStart - lead
      let oldEnd = end.oldStart + end.oldCount + trail
      let newEnd = end.newStart + end.newCount + trail

      var lines: [DiffLine] = []
      func append(_ kind: DiffLine.Kind, old oldIndex: Int?, new newIndex: Int?) {
        let text = oldIndex.map { old.text($0) } ?? newIndex.map { new.text($0) } ?? ""
        let missingNewline =
          (kind != .added && oldIndex == old.count - 1 && old.endsWithoutNewline)
          || (kind == .added && newIndex == new.count - 1 && new.endsWithoutNewline)
        lines.append(
          DiffLine(
            id: lineID, kind: kind, text: text, oldLine: oldIndex.map { $0 + 1 }, newLine: newIndex.map { $0 + 1 },
            noNewlineAtEnd: missingNewline))
        lineID += 1
      }
      var oldLine = oldStart
      var newLine = newStart
      for change in changes[index...last] {
        while oldLine < change.oldStart {
          append(.context, old: oldLine, new: newLine)
          oldLine += 1
          newLine += 1
        }
        for removed in change.oldStart..<change.oldStart + change.oldCount { append(.removed, old: removed, new: nil) }
        for added in change.newStart..<change.newStart + change.newCount { append(.added, old: nil, new: added) }
        oldLine = change.oldStart + change.oldCount
        newLine = change.newStart + change.newCount
      }
      while oldLine < oldEnd {
        append(.context, old: oldLine, new: newLine)
        oldLine += 1
        newLine += 1
      }
      let oldCount = oldEnd - oldStart
      let newCount = newEnd - newStart
      hunks.append(
        DiffHunk(
          id: hunks.count, oldStart: oldCount == 0 ? oldStart : oldStart + 1, oldCount: oldCount,
          newStart: newCount == 0 ? newStart : newStart + 1, newCount: newCount,
          section: functionContext(old, before: oldStart), lines: lines))
      index = last + 1
    }
    return hunks
  }

  /// git's default function line: the nearest line above the hunk starting with a letter, `_` or `$`, cut to 80
  /// bytes without trailing whitespace.
  static func functionContext(_ lines: Lines, before start: Int) -> String {
    var index = start - 1
    while index >= 0 {
      let bytes = lines.bytes(index)
      if let first = bytes.first,
        (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A) || first == 0x5F || first == 0x24
      {
        var text = Array(bytes.prefix(80))
        while let last = text.last, last == 0x20 || (0x09...0x0D).contains(last) { text.removeLast() }
        return String(decoding: text, as: UTF8.self)
      }
      index -= 1
    }
    return ""
  }
}
