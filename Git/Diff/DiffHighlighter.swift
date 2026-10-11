import CodeKit
import Foundation
import GitKit
import SwiftUI

/// Syntax-colors diff lines with CodeKit (`../Code`). This is the only file that imports it.
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

  /// Display text for every line in `diff`, keyed by line id, colored when the language is known.
  static func render(
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
