import Foundation

/// One line of a `.gitignore` file.
struct IgnorePattern {
  var pattern: [UInt8]
  var negated: Bool
  /// Written with a trailing `/`: matches folders only.
  var directoryOnly: Bool
  /// Contains a `/` (besides a trailing one): matched against the path below `base`, not just the name.
  var matchesPath: Bool
  /// The folder of the file the pattern came from, `""` or ending in `/`.
  var base: String

  init?(line: Substring, base: String) {
    var bytes = Array(line.utf8)
    if bytes.last == 0x0D { bytes.removeLast() }
    // Trailing spaces don't count unless escaped.
    while bytes.last == 0x20, !(bytes.count >= 2 && bytes[bytes.count - 2] == UInt8(ascii: "\\")) {
      bytes.removeLast()
    }
    guard let first = bytes.first, first != UInt8(ascii: "#") else { return nil }
    negated = first == UInt8(ascii: "!")
    if negated { bytes.removeFirst() }
    directoryOnly = bytes.last == UInt8(ascii: "/")
    if directoryOnly { bytes.removeLast() }
    guard !bytes.isEmpty else { return nil }
    matchesPath = bytes.contains(UInt8(ascii: "/"))
    if bytes.first == UInt8(ascii: "/") { bytes.removeFirst() }
    pattern = bytes
    self.base = base
  }

  /// Whether the pattern matches `path` (relative to the repository), which is a folder when `isDirectory`.
  func matches(_ path: String, name: Substring, isDirectory: Bool) -> Bool {
    if directoryOnly && !isDirectory { return false }
    if matchesPath {
      guard path.hasPrefix(base) else { return false }
      return Wildmatch.matches(pattern, Array(path.utf8.dropFirst(base.utf8.count)), pathname: true)
    }
    return Wildmatch.matches(pattern, Array(name.utf8), pathname: false)
  }
}

/// The ignore rules of a working tree: `.git/info/exclude`, then each folder's `.gitignore`, deeper files and later
/// lines winning, as in git.
final class IgnoreRules {
  private let worktree: URL
  private let exclude: [IgnorePattern]
  private var folders: [String: [IgnorePattern]] = [:]

  init(worktree: URL, gitDirectory: URL) {
    self.worktree = worktree
    let text = (try? String(contentsOf: gitDirectory.appendingPathComponent("info/exclude"), encoding: .utf8)) ?? ""
    exclude = Self.parse(text, base: "")
  }

  static func parse(_ text: String, base: String) -> [IgnorePattern] {
    text.split(separator: "\n").compactMap { IgnorePattern(line: $0, base: base) }
  }

  /// The patterns of `folder`'s `.gitignore` (`""` for the root, else ending in `/`).
  private func patterns(in folder: String) -> [IgnorePattern] {
    if let cached = folders[folder] { return cached }
    let url = worktree.appendingPathComponent(folder + ".gitignore")
    let patterns = (try? String(contentsOf: url, encoding: .utf8)).map { Self.parse($0, base: folder) } ?? []
    folders[folder] = patterns
    return patterns
  }

  /// Whether `path` is ignored. Its parent folders aren't checked: callers don't look inside ignored folders.
  func isIgnored(_ path: String, isDirectory: Bool) -> Bool {
    let name = path.split(separator: "/").last ?? Substring(path)
    var folder = path
    // From the file's own folder up to the root.
    while true {
      if let slash = folder.lastIndex(of: "/") {
        folder = String(folder[...slash])
        folder.removeLast()
      } else {
        folder = ""
      }
      let base = folder.isEmpty ? "" : folder + "/"
      for pattern in patterns(in: base).reversed() where pattern.matches(path, name: name, isDirectory: isDirectory) {
        return !pattern.negated
      }
      if folder.isEmpty { break }
    }
    for pattern in exclude.reversed() where pattern.matches(path, name: name, isDirectory: isDirectory) {
      return !pattern.negated
    }
    return false
  }

  /// Like `isIgnored`, but also true when a parent folder is ignored: for paths named directly.
  func isIgnoredWithParents(_ path: String, isDirectory: Bool) -> Bool {
    let components = path.split(separator: "/")
    for count in 1..<max(components.count, 1) {
      if isIgnored(components.prefix(count).joined(separator: "/"), isDirectory: true) { return true }
    }
    return isIgnored(path, isDirectory: isDirectory)
  }
}
