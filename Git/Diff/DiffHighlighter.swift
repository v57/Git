import Foundation
import GitKit
import Md
import SwiftUI

/// Syntax-colors diff lines with Markdown's code highlighter. This is the only file that imports
/// `Md`; a dedicated code library will replace it.
///
/// The scanner carries state across lines (block comments, multi-line strings), so each side is
/// tokenized as a whole file when its text is available, and the tokens are mapped onto diff
/// lines by line number. Without the file, the side is rebuilt from the hunks.
nonisolated enum DiffHighlighter {
  static let maxFileSize = 1_000_000

  /// The language name the highlighter knows for `path`, or `nil`.
  static func language(for path: String) -> String? {
    let ext = (path as NSString).pathExtension.lowercased()
    guard !ext.isEmpty, CodeHighlighter.spec(forLanguage: ext) != nil else { return nil }
    return ext
  }

  /// Display text for every line in `diff`, keyed by line id, colored when the language is known.
  static func render(
    _ diff: FileDiff, oldText: String?, newText: String?, isDark: Bool
  ) -> [Int: AttributedString] {
    let lines = diff.lines
    guard let language = language(for: diff.path) else {
      return Dictionary(uniqueKeysWithValues: lines.map { ($0.id, plain($0.text)) })
    }
    let scheme = CodeColorScheme.systemAware(isDark: isDark)

    // Tokens per side, keyed by 1-based line number (or by line id for rebuilt sides).
    let old = side(lines.filter { $0.kind != .added }, number: \.oldLine, text: oldText, language: language)
    let new = side(lines.filter { $0.kind != .removed }, number: \.newLine, text: newText, language: language)

    var result: [Int: AttributedString] = [:]
    for line in lines {
      let tokens = line.kind == .removed ? old[line.id] : new[line.id]
      result[line.id] = colored(line.text, tokens: tokens ?? [], scheme: scheme)
    }
    return result
  }

  typealias LineTokens = [(range: NSRange, kind: SyntaxKind)]

  /// Tokens for each of `lines` (by line id), from the whole file when it is available and
  /// matches, else from the lines themselves.
  private static func side(
    _ lines: [DiffLine], number: KeyPath<DiffLine, Int?>, text: String?, language: String
  ) -> [Int: LineTokens] {
    if let text, text.utf16.count <= maxFileSize {
      let fileLines = tokensByLine(text, language: language)
      // Use the file only if it matches the diff (it may have changed since the diff was read).
      let matches = lines.allSatisfy { line in
        guard let n = line[keyPath: number], n - 1 < fileLines.count else { return false }
        return fileLines[n - 1].text == line.text
      }
      if matches {
        var result: [Int: LineTokens] = [:]
        for line in lines {
          if let n = line[keyPath: number] { result[line.id] = fileLines[n - 1].tokens }
        }
        return result
      }
    }
    let rebuilt = lines.map(\.text).joined(separator: "\n")
    let fileLines = tokensByLine(rebuilt, language: language)
    var result: [Int: LineTokens] = [:]
    for (index, line) in lines.enumerated() where index < fileLines.count {
      result[line.id] = fileLines[index].tokens
    }
    return result
  }

  /// Splits `text` into lines and assigns each token (or the part of it on that line) to its
  /// line, with ranges relative to the line.
  private static func tokensByLine(_ text: String, language: String)
    -> [(text: String, tokens: LineTokens)]
  {
    let ns = text as NSString
    var starts: [Int] = [0]
    var location = 0
    while location < ns.length {
      let range = ns.range(of: "\n", range: NSRange(location: location, length: ns.length - location))
      if range.location == NSNotFound { break }
      starts.append(range.location + 1)
      location = range.location + 1
    }
    var lines: [(text: String, tokens: LineTokens)] = starts.enumerated().map { index, start in
      let end = index + 1 < starts.count ? starts[index + 1] - 1 : ns.length
      return (ns.substring(with: NSRange(location: start, length: end - start)), [])
    }
    for token in CodeHighlighter.tokens(in: text, language: language) {
      var lineIndex = lineIndex(of: token.range.location, in: starts)
      var remaining = token.range
      while remaining.length > 0, lineIndex < lines.count {
        let lineStart = starts[lineIndex]
        let lineLength = (lines[lineIndex].text as NSString).length
        let localStart = remaining.location - lineStart
        let localLength = min(remaining.length, lineLength - localStart)
        if localLength > 0 {
          lines[lineIndex].tokens.append(
            (NSRange(location: localStart, length: localLength), token.kind))
        }
        let consumed = max(localLength, 0) + 1  // the newline
        remaining = NSRange(
          location: remaining.location + consumed, length: max(remaining.length - consumed, 0))
        lineIndex += 1
      }
    }
    return lines
  }

  private static func lineIndex(of offset: Int, in starts: [Int]) -> Int {
    var low = 0
    var high = starts.count - 1
    while low < high {
      let mid = (low + high + 1) / 2
      if starts[mid] <= offset { low = mid } else { high = mid - 1 }
    }
    return low
  }

  /// The line with tabs expanded and a trailing `\r` removed, colored by `tokens` (later tokens
  /// win where they overlap).
  private static func colored(_ text: String, tokens: LineTokens, scheme: CodeColorScheme)
    -> AttributedString
  {
    let ns = text as NSString
    var colors = [UInt32?](repeating: nil, count: ns.length)
    for token in tokens {
      let end = min(token.range.location + token.range.length, ns.length)
      guard token.range.location < end else { continue }
      for index in token.range.location..<end { colors[index] = scheme.color(for: token.kind) }
    }
    var result = AttributedString()
    var start = 0
    while start < ns.length {
      var end = start + 1
      while end < ns.length, colors[end] == colors[start] { end += 1 }
      var piece = AttributedString(display(ns.substring(with: NSRange(location: start, length: end - start))))
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
    var text = text
    if text.hasSuffix("\r") { text.removeLast() }
    return text.replacingOccurrences(of: "\t", with: "    ")
  }
}

extension Color {
  nonisolated init(rgb: UInt32) {
    self.init(
      .sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
      blue: Double(rgb & 0xFF) / 255)
  }
}
