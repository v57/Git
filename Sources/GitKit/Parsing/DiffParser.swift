import Foundation

/// Parses unified diffs from `git diff` / `git show`.
enum DiffParser {
  static func parse(_ data: Data) -> [FileDiff] {
    var invalidUTF8 = false
    let text: String
    if let valid = String(data: data, encoding: .utf8) {
      text = valid
    } else {
      text = String(decoding: data, as: UTF8.self)
      invalidUTF8 = true
    }
    var diffs = parse(text)
    if invalidUTF8 {
      for index in diffs.indices { diffs[index].hasInvalidUTF8 = true }
    }
    return diffs
  }

  static func parse(_ text: String) -> [FileDiff] {
    // Split on the scalar: "\r\n" is one Character, so a CRLF file would be one line. Lines keep their "\r".
    var lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { Substring($0) }[...]
    if lines.last == "" { lines.removeLast() }
    var files: [FileDiff] = []
    var current: FileDiff?
    var lineID = 0

    func finish() {
      if let file = current { files.append(file) }
      current = nil
      lineID = 0
    }

    while let line = lines.popFirst() {
      if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ")
        || line.hasPrefix("diff --combined ")
      {
        finish()
        let paths = pathsFromDiffHeader(line)
        current = FileDiff(oldPath: paths.old, newPath: paths.new)
        continue
      }
      guard var file = current else { continue }
      defer { current = file }

      if line.hasPrefix("@@") {
        guard var hunk = parseHunkHeader(line, id: file.hunks.count) else { continue }
        var oldLeft = hunk.oldCount
        var newLeft = hunk.newCount
        var oldNumber = hunk.oldStart
        var newNumber = hunk.newStart
        while oldLeft > 0 || newLeft > 0 || lines.first?.hasPrefix("\\") == true {
          guard let body = lines.first else { break }
          if body.hasPrefix("\\") {
            lines.removeFirst()
            if !hunk.lines.isEmpty { hunk.lines[hunk.lines.count - 1].noNewlineAtEnd = true }
            continue
          }
          let marker = body.first ?? " "
          let content = body.isEmpty ? "" : String(body.dropFirst())
          switch marker {
          case "+" where newLeft > 0:
            hunk.lines.append(
              DiffLine(id: lineID, kind: .added, text: content, oldLine: nil, newLine: newNumber))
            newNumber += 1
            newLeft -= 1
          case "-" where oldLeft > 0:
            hunk.lines.append(
              DiffLine(id: lineID, kind: .removed, text: content, oldLine: oldNumber, newLine: nil))
            oldNumber += 1
            oldLeft -= 1
          case " " where oldLeft > 0 && newLeft > 0:
            hunk.lines.append(
              DiffLine(
                id: lineID, kind: .context, text: content, oldLine: oldNumber, newLine: newNumber))
            oldNumber += 1
            newNumber += 1
            oldLeft -= 1
            newLeft -= 1
          default:
            // Malformed or truncated hunk: stop here and let the outer loop resync.
            oldLeft = 0
            newLeft = 0
            continue
          }
          lines.removeFirst()
          lineID += 1
        }
        file.hunks.append(hunk)
      } else if line.hasPrefix("new file mode ") {
        file.oldPath = nil
        file.newMode = String(line.dropFirst(14))
      } else if line.hasPrefix("deleted file mode ") {
        file.newPath = nil
        file.oldMode = String(line.dropFirst(18))
      } else if line.hasPrefix("old mode ") {
        file.oldMode = String(line.dropFirst(9))
      } else if line.hasPrefix("new mode ") {
        file.newMode = String(line.dropFirst(9))
      } else if line.hasPrefix("similarity index ") {
        file.similarity = Int(line.dropFirst(17).dropLast())
      } else if line.hasPrefix("rename from ") {
        file.isRename = true
        file.oldPath = unquote(line.dropFirst(12))
      } else if line.hasPrefix("rename to ") {
        file.isRename = true
        file.newPath = unquote(line.dropFirst(10))
      } else if line.hasPrefix("copy from ") {
        file.isCopy = true
        file.oldPath = unquote(line.dropFirst(10))
      } else if line.hasPrefix("copy to ") {
        file.isCopy = true
        file.newPath = unquote(line.dropFirst(8))
      } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
        file.isBinary = true
      } else if line.hasPrefix("index ") {
        // `index abc..def 100644`: the mode is unchanged on both sides.
        let parts = line.split(separator: " ")
        if parts.count == 3 {
          file.oldMode = file.oldMode ?? String(parts[2])
          file.newMode = file.newMode ?? String(parts[2])
        }
      } else if line.hasPrefix("--- ") {
        file.oldPath = headerPath(line.dropFirst(4), prefix: "a/")
      } else if line.hasPrefix("+++ ") {
        file.newPath = headerPath(line.dropFirst(4), prefix: "b/")
      }
    }
    finish()
    return files
  }

  /// `@@ -1,3 +1,4 @@ func foo()`.
  static func parseHunkHeader(_ line: Substring, id: Int) -> DiffHunk? {
    let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
    guard parts.count >= 4, parts[0] == "@@", parts[3] == "@@",
      let old = parseRange(parts[1].dropFirst()), let new = parseRange(parts[2].dropFirst())
    else { return nil }
    return DiffHunk(
      id: id, oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count,
      section: parts.count > 4 ? String(parts[4]) : "", lines: [])
  }

  private static func parseRange(_ text: Substring) -> (start: Int, count: Int)? {
    let parts = text.split(separator: ",")
    guard let start = parts.first.flatMap({ Int($0) }) else { return nil }
    let count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
    return (start, count)
  }

  /// `--- a/path`, `+++ b/path`, `/dev/null`, or a quoted path. git appends a tab after paths
  /// with spaces.
  private static func headerPath(_ raw: Substring, prefix: String) -> String? {
    var value = raw
    if value.last == "\t" { value = value.dropLast() }
    if value == "/dev/null" { return nil }
    let path = unquote(value)
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
  }

  /// Best guess from `diff --git a/x b/x`; the `---`/`+++`/rename lines refine it.
  private static func pathsFromDiffHeader(_ line: Substring) -> (old: String?, new: String?) {
    guard line.hasPrefix("diff --git ") else { return (nil, nil) }
    let rest = line.dropFirst(11)
    if rest.hasPrefix("\"") {
      // Quoted paths: "a/x" "b/y" (or mixed); split on the closing quote.
      let scanner = rest.dropFirst()
      var escaped = false
      var end = scanner.startIndex
      for index in scanner.indices {
        let character = scanner[index]
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          end = index
          break
        }
      }
      let old = unquote(rest[rest.startIndex...end])
      let new = unquote(rest[rest.index(after: end)...].drop { $0 == " " })
      return (strip(old, "a/"), strip(new, "b/"))
    }
    // Unquoted: when both sides are equal the line is "a/P b/P", so split at the middle.
    let count = rest.count
    if count % 2 == 1 {
      let middle = rest.index(rest.startIndex, offsetBy: count / 2)
      let old = rest[..<middle]
      let new = rest[rest.index(after: middle)...]
      if old.hasPrefix("a/"), new.hasPrefix("b/"), old.dropFirst(2) == new.dropFirst(2) {
        return (String(old.dropFirst(2)), String(new.dropFirst(2)))
      }
    }
    if let range = rest.range(of: " b/", options: .backwards) {
      return (strip(String(rest[..<range.lowerBound]), "a/"), String(rest[range.upperBound...]))
    }
    return (nil, nil)
  }

  private static func strip(_ path: String, _ prefix: String) -> String {
    path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
  }

  /// Undoes git's C-style quoting (`"a/caf\303\251"`).
  static func unquote(_ raw: Substring) -> String {
    guard raw.count >= 2, raw.first == "\"", raw.last == "\"" else { return String(raw) }
    var bytes: [UInt8] = []
    var iterator = Array(raw.dropFirst().dropLast().utf8)[...]
    while let byte = iterator.popFirst() {
      guard byte == UInt8(ascii: "\\"), let next = iterator.popFirst() else {
        bytes.append(byte)
        continue
      }
      switch next {
      case UInt8(ascii: "n"): bytes.append(0x0A)
      case UInt8(ascii: "t"): bytes.append(0x09)
      case UInt8(ascii: "r"): bytes.append(0x0D)
      case UInt8(ascii: "a"): bytes.append(0x07)
      case UInt8(ascii: "b"): bytes.append(0x08)
      case UInt8(ascii: "f"): bytes.append(0x0C)
      case UInt8(ascii: "v"): bytes.append(0x0B)
      case UInt8(ascii: "0")...UInt8(ascii: "7"):
        var value = Int(next - UInt8(ascii: "0"))
        for _ in 0..<2 {
          guard let digit = iterator.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit)
          else { break }
          iterator.removeFirst()
          value = value * 8 + Int(digit - UInt8(ascii: "0"))
        }
        bytes.append(UInt8(truncatingIfNeeded: value))
      default: bytes.append(next)
      }
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}
