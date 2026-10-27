import Foundation

/// A git config file (`.git/config`), kept as its lines so edits leave the rest of the file as it was.
///
/// Keys are `section.key` or `section.subsection.key`; sections and keys compare case-insensitively, subsections
/// exactly, as in git.
struct GitConfig {
  private var lines: [String]

  init(text: String) {
    lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
  }

  init(url: URL) {
    self.init(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
  }

  var text: String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }

  func write(to url: URL) throws {
    try LockFile.write(Data(text.utf8), to: url)
  }

  /// A key split into its lowercased section, its subsection and its lowercased name.
  struct Key: Equatable {
    var section: String
    var subsection: String?
    var name: String

    init?(_ key: String) {
      guard let first = key.firstIndex(of: "."), let last = key.lastIndex(of: "."), first != key.startIndex,
        key.index(after: last) != key.endIndex
      else { return nil }
      section = key[..<first].lowercased()
      name = key[key.index(after: last)...].lowercased()
      subsection = first == last ? nil : String(key[key.index(after: first)..<last])
    }
  }

  private enum Line {
    case section(String, String?)
    case entry(String, String)
    case other
  }

  /// `[remote "origin"]`, `[core]` or the old `[branch.main]`.
  private static func parseSection(_ line: Substring) -> (String, String?)? {
    guard line.hasPrefix("["), let close = line.lastIndex(of: "]") else { return nil }
    let inside = line[line.index(after: line.startIndex)..<close]
    if let quote = inside.firstIndex(of: "\"") {
      let name = inside[..<quote].trimmingCharacters(in: .whitespaces).lowercased()
      var subsection = ""
      var escaped = false
      for character in inside[inside.index(after: quote)...] {
        if escaped {
          subsection.append(character)
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          break
        } else {
          subsection.append(character)
        }
      }
      return (name, subsection)
    }
    if let dot = inside.firstIndex(of: ".") {
      return (inside[..<dot].lowercased(), String(inside[inside.index(after: dot)...]))
    }
    return (inside.trimmingCharacters(in: .whitespaces).lowercased(), nil)
  }

  private static func parse(_ line: String) -> Line {
    let trimmed = line.drop { $0 == " " || $0 == "\t" }
    if trimmed.hasPrefix("[") {
      if let (section, subsection) = parseSection(trimmed) { return .section(section, subsection) }
      return .other
    }
    if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { return .other }
    let nameEnd = trimmed.firstIndex { !($0.isLetter || $0.isNumber || $0 == "-") } ?? trimmed.endIndex
    let name = trimmed[..<nameEnd].lowercased()
    guard !name.isEmpty else { return .other }
    let rest = trimmed[nameEnd...].drop { $0 == " " || $0 == "\t" }
    // A key without `=` is a boolean true.
    guard rest.first == "=" else { return .entry(name, "true") }
    return .entry(name, parseValue(rest.dropFirst()))
  }

  /// Unquotes a value, drops a trailing comment and handles `\n`, `\t`, `\"` and `\\`.
  private static func parseValue(_ raw: Substring) -> String {
    var value = ""
    var quoted = false
    var escaped = false
    var pendingSpace = ""
    for character in raw.drop(while: { $0 == " " || $0 == "\t" }) {
      if escaped {
        switch character {
        case "n": value += pendingSpace + "\n"
        case "t": value += pendingSpace + "\t"
        case "b": value += pendingSpace
        default: value += pendingSpace + String(character)
        }
        pendingSpace = ""
        escaped = false
        continue
      }
      switch character {
      case "\\": escaped = true
      case "\"": quoted.toggle()
      case "#" where !quoted, ";" where !quoted: return value
      case " " where !quoted, "\t" where !quoted: pendingSpace.append(character)
      default:
        value += pendingSpace + String(character)
        pendingSpace = ""
      }
    }
    return value
  }

  /// Every value of `key`, in file order.
  func values(_ key: String) -> [String] {
    guard let key = Key(key) else { return [] }
    var values: [String] = []
    var inSection = false
    for line in lines {
      switch Self.parse(line) {
      case .section(let section, let subsection):
        inSection = section == key.section && subsection == key.subsection
      case .entry(let name, let value) where inSection && name == key.name:
        values.append(value)
      default: break
      }
    }
    return values
  }

  /// The last value of `key`, which wins in git.
  func value(_ key: String) -> String? { values(key).last }

  func bool(_ key: String, default fallback: Bool) -> Bool {
    guard let value = value(key)?.lowercased() else { return fallback }
    return ["true", "yes", "on", "1"].contains(value)
  }

  /// The subsections of `section` in file order: the remotes for `remote`.
  func subsections(of section: String) -> [String] {
    var names: [String] = []
    for line in lines {
      if case .section(let name, let subsection?) = Self.parse(line), name == section.lowercased(),
        !names.contains(subsection)
      {
        names.append(subsection)
      }
    }
    return names
  }

  /// Sets `key` (replacing its last value, or adding it) or removes every value with `nil`.
  mutating func set(_ key: String, _ value: String?) throws {
    guard let parsed = Key(key) else { throw GitEngineError.refused("“\(key)” isn't a config key.") }
    var sectionEnd: Int?
    var lastEntry: Int?
    var inSection = false
    var matches: [Int] = []
    for (number, line) in lines.enumerated() {
      switch Self.parse(line) {
      case .section(let section, let subsection):
        inSection = section == parsed.section && subsection == parsed.subsection
        if inSection { sectionEnd = number }
      case .entry(let name, _) where inSection:
        sectionEnd = number
        if name == parsed.name {
          matches.append(number)
          lastEntry = number
        }
      default:
        if inSection, !line.trimmingCharacters(in: .whitespaces).isEmpty { sectionEnd = number }
      }
    }
    guard let value else {
      for number in matches.reversed() { lines.remove(at: number) }
      return
    }
    let line = "\t\(parsed.name) = \(Self.encode(value))"
    if let lastEntry {
      lines[lastEntry] = line
    } else if let sectionEnd {
      lines.insert(line, at: sectionEnd + 1)
    } else {
      lines.append(Self.sectionHeader(parsed))
      lines.append(line)
    }
  }

  /// Adds one more value to a multi-valued key (e.g. a second `remote.origin.fetch`).
  mutating func add(_ key: String, _ value: String) throws {
    guard let parsed = Key(key) else { throw GitEngineError.refused("“\(key)” isn't a config key.") }
    var sectionEnd: Int?
    var inSection = false
    for (number, line) in lines.enumerated() {
      if case .section(let section, let subsection) = Self.parse(line) {
        inSection = section == parsed.section && subsection == parsed.subsection
      }
      if inSection, !line.trimmingCharacters(in: .whitespaces).isEmpty { sectionEnd = number }
    }
    let line = "\t\(parsed.name) = \(Self.encode(value))"
    if let sectionEnd {
      lines.insert(line, at: sectionEnd + 1)
    } else {
      lines.append(Self.sectionHeader(parsed))
      lines.append(line)
    }
  }

  private static func sectionHeader(_ key: Key) -> String {
    guard let subsection = key.subsection else { return "[\(key.section)]" }
    let escaped = subsection.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return "[\(key.section) \"\(escaped)\"]"
  }

  private static func encode(_ value: String) -> String {
    var escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    if escaped.first == " " || escaped.last == " " || escaped.contains("#") || escaped.contains(";") {
      escaped = "\"\(escaped)\""
    }
    return escaped
  }
}
