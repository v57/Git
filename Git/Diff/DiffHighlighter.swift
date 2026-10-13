import CodeHighlighting
import Foundation
import GitKit
import SwiftUI

/// Syntax-colors diff lines with CodeHighlighting (`../Code`). This is the only file that imports it.
///
/// Highlighting carries state across lines (block comments, multi-line strings), so each side is
/// highlighted as a whole file when its text is available, and the tokens are mapped onto diff
/// lines by line number. Without the file, the side is rebuilt from the hunks.
nonisolated enum DiffHighlighter {
  static let maxFileSize = 1_000_000

  /// Whether `path` may be highlightable: a known name or extension, or no extension (a `#!`
  /// line may decide once the contents are read).
  static func mayHighlight(_ path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    return url.pathExtension.isEmpty || Language.detect(url: url) != nil
  }

  /// Display text for every line in `diff`, keyed by line id: colored when the language is known,
  /// with the changed part of each removed/added line pair emphasized.
  static func render(
    _ diff: FileDiff, oldText: String?, newText: String?, isDark: Bool
  ) -> [Int: AttributedString] {
    var result = colored(diff, oldText: oldText, newText: newText, isDark: isDark)
    emphasizeChanges(in: diff, &result)
    return result
  }

  private static func colored(
    _ diff: FileDiff, oldText: String?, newText: String?, isDark: Bool
  ) -> [Int: AttributedString] {
    let lines = diff.lines
    let firstLine = (newText ?? oldText).map { String($0.prefix { $0 != "\n" }) }
    guard let spec = Language.detect(url: URL(fileURLWithPath: diff.path), firstLine: firstLine)
    else {
      return Dictionary(uniqueKeysWithValues: lines.map { ($0.id, plain($0.text)) })
    }
    let scheme = CodeColorScheme.systemAware(isDark: isDark)
    let old = side(lines.filter { $0.kind != .added }, number: \.oldLine, text: oldText, spec: spec)
    let new = side(lines.filter { $0.kind != .removed }, number: \.newLine, text: newText, spec: spec)

    var result: [Int: AttributedString] = [:]
    for line in lines {
      let tokens = line.kind == .removed ? old[line.id] : new[line.id]
      result[line.id] = colored(line.text, tokens: tokens ?? [], scheme: scheme)
    }
    return result
  }

  /// Pairs the n-th removed and n-th added line of each block of changes and gives the part
  /// between their common prefix and suffix a stronger background, so an edit inside a line
  /// stands out (GitHub-style). Lines with nothing in common are left alone.
  private static func emphasizeChanges(in diff: FileDiff, _ result: inout [Int: AttributedString]) {
    for hunk in diff.hunks {
      let lines = hunk.lines
      var index = 0
      while index < lines.count {
        guard lines[index].kind == .removed else {
          index += 1
          continue
        }
        var removed: [DiffLine] = []
        while index < lines.count, lines[index].kind == .removed {
          removed.append(lines[index])
          index += 1
        }
        var added: [DiffLine] = []
        while index < lines.count, lines[index].kind == .added {
          added.append(lines[index])
          index += 1
        }
        for (old, new) in zip(removed, added) {
          let a = Array(display(old.text))
          let b = Array(display(new.text))
          var prefix = 0
          while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
          var suffix = 0
          while suffix < min(a.count, b.count) - prefix,
            a[a.count - 1 - suffix] == b[b.count - 1 - suffix]
          {
            suffix += 1
          }
          // Only worth it when a good part of the line is shared.
          let shared = prefix + suffix
          guard shared >= 3, Double(shared) >= 0.25 * Double(min(a.count, b.count)) else { continue }
          emphasize(&result[old.id], from: prefix, to: a.count - suffix, color: .red)
          emphasize(&result[new.id], from: prefix, to: b.count - suffix, color: .green)
        }
      }
    }
  }

  private static func emphasize(
    _ text: inout AttributedString?, from start: Int, to end: Int, color: Color
  ) {
    guard var string = text, start < end else { return }
    let characters = string.characters
    guard
      let lower = characters.index(characters.startIndex, offsetBy: start, limitedBy: characters.endIndex),
      let upper = characters.index(characters.startIndex, offsetBy: end, limitedBy: characters.endIndex)
    else { return }
    string[lower..<upper].backgroundColor = color.opacity(0.35)
    text = string
  }

  /// Tokens for each of `lines` (by line id, ranges relative to the line), from the whole file
  /// when it is available and matches the diff, else from the lines themselves.
  private static func side(
    _ lines: [DiffLine], number: KeyPath<DiffLine, Int?>, text: String?, spec: LanguageSpec
  ) -> [Int: [CodeToken]] {
    if let text, text.utf16.count <= maxFileSize {
      let ns = text as NSString
      let highlighter = SyntaxHighlighter(text: ns, spec: spec)
      // The file may have changed since the diff was read; use it only if it still matches.
      let matches = lines.allSatisfy { line in
        guard let n = line[keyPath: number], n - 1 < highlighter.lines.count else { return false }
        let content = ns.substring(with: highlighter.lines.contentRange(ofLine: n - 1, in: ns))
        return content == withoutCarriageReturn(line.text)
      }
      if matches {
        var result: [Int: [CodeToken]] = [:]
        for line in lines {
          guard let n = line[keyPath: number] else { continue }
          result[line.id] = relative(highlighter, line: n - 1)
        }
        return result
      }
    }
    let rebuilt = lines.map { withoutCarriageReturn($0.text) }.joined(separator: "\n") as NSString
    let highlighter = SyntaxHighlighter(text: rebuilt, spec: spec)
    var result: [Int: [CodeToken]] = [:]
    for (index, line) in lines.enumerated() where index < highlighter.lines.count {
      result[line.id] = relative(highlighter, line: index)
    }
    return result
  }

  /// The tokens of `line` with ranges relative to the line start.
  private static func relative(_ highlighter: SyntaxHighlighter, line: Int) -> [CodeToken] {
    let start = highlighter.lines.starts[line]
    return highlighter.tokens(ofLine: line).map {
      CodeToken(
        range: NSRange(location: $0.range.location - start, length: $0.range.length),
        kind: $0.kind)
    }
  }

  private static func withoutCarriageReturn(_ text: String) -> String {
    text.hasSuffix("\r") ? String(text.dropLast()) : text
  }

  /// The line with tabs expanded and a trailing `\r` removed, colored by `tokens` (later tokens
  /// win where they overlap).
  private static func colored(_ text: String, tokens: [CodeToken], scheme: CodeColorScheme)
    -> AttributedString
  {
    let ns = withoutCarriageReturn(text) as NSString
    var colors = [UInt32?](repeating: nil, count: ns.length)
    for token in tokens {
      let end = min(token.range.location + token.range.length, ns.length)
      guard token.range.location >= 0, token.range.location < end else { continue }
      for index in token.range.location..<end { colors[index] = scheme.color(for: token.kind) }
    }
    var result = AttributedString()
    var start = 0
    while start < ns.length {
      var end = start + 1
      while end < ns.length, colors[end] == colors[start] { end += 1 }
      var piece = AttributedString(
        display(ns.substring(with: NSRange(location: start, length: end - start))))
      if let rgb = colors[start] { piece.foregroundColor = Color(rgb: rgb) }
      result += piece
      start = end
    }
    return result
  }

  static func plain(_ text: String) -> AttributedString {
    AttributedString(display(text))
  }

  /// Tabs as four spaces (so the column width can be computed) and no carriage return.
  static func display(_ text: String) -> String {
    withoutCarriageReturn(text).replacingOccurrences(of: "\t", with: "    ")
  }
}

extension Color {
  nonisolated init(rgb: UInt32) {
    self.init(
      .sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
      blue: Double(rgb & 0xFF) / 255)
  }
}
