import Foundation

/// One entry of a tree object.
struct TreeEntry: Sendable, Hashable {
  var name: String
  var mode: FileMode
  var id: ObjectID
}

/// A file (or gitlink) at a path, from a flattened tree or the index.
struct TreeFile: Sendable, Hashable {
  var mode: FileMode
  var id: ObjectID
}

enum TreeObject {
  /// `<mode> <name>\0<20 bytes>` entries.
  static func parse(_ data: Data) throws -> [TreeEntry] {
    try data.withUnsafeBytes { buffer in
      var entries: [TreeEntry] = []
      var position = 0
      while position < buffer.count {
        guard let space = buffer[position...].firstIndex(of: 0x20),
          let nul = buffer[space...].firstIndex(of: 0), nul + 20 < buffer.count
        else { throw GitEngineError.corrupt("A tree object is damaged.") }
        var mode: UInt32 = 0
        for digit in buffer[position..<space] { mode = mode * 8 + UInt32(digit &- 0x30) }
        let name = String(decoding: UnsafeRawBufferPointer(rebasing: buffer[(space + 1)..<nul]), as: UTF8.self)
        let entryMode = FileMode(raw: mode)
        try checkName(name, mode: entryMode)
        entries.append(TreeEntry(name: name, mode: entryMode, id: ObjectID(buffer, at: nul + 1)))
        position = nul + 21
      }
      return entries
    }
  }

  /// Refuses an entry name git itself refuses to check out (`verify_path`, fsck's `hasDotgit` and friends): empty,
  /// `.`, `..`, one holding `/` (or `\\` on Windows), and `.git` in any case or spelling the file system treats as `.git`
  /// (HFS+'s ignorable code points, NTFS's `git~1`, trailing dots and spaces, `.git::$INDEX_ALLOCATION`), and
  /// `.gitmodules` as a symlink. A tree from a hostile server could otherwise write outside the working tree or into
  /// `.git` at checkout (security audit H3).
  static func checkName(_ name: String, mode: FileMode) throws {
    guard isSafeName(name, mode: mode) else {
      throw GitEngineError.corrupt("A tree object has an entry named “\(name)”, which can’t be checked out safely.")
    }
  }

  static func isSafeName(_ name: String, mode: FileMode) -> Bool {
    if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\0") { return false }
    #if os(Windows)
      if name.contains("\\") { return false }
    #endif
    if isGitName(name, "git") { return false }
    if mode == .symlink, isGitName(name, "gitmodules") || isNTFSShortName(name, "gitmod~1") { return false }
    return true
  }

  /// Whether `name` is `.<base>` as a case-insensitive, HFS+ or NTFS file system would see it.
  private static func isGitName(_ name: String, _ base: String) -> Bool {
    // HFS+ ignores these code points when it compares names.
    let ignorable: (Unicode.Scalar) -> Bool = {
      (0x200C...0x200F).contains($0.value) || (0x202A...0x202E).contains($0.value)
        || (0x206A...0x206F).contains($0.value) || $0.value == 0xFEFF
    }
    let visible = String(String.UnicodeScalarView(name.unicodeScalars.filter { !ignorable($0) })).lowercased()
    if visible == "." + base { return true }
    // NTFS drops trailing dots and spaces, and `name:stream` is the file `name`.
    let dotted = "." + base
    if visible.hasPrefix(dotted) {
      let rest = visible.dropFirst(dotted.count)
      if rest.first == ":" || rest.allSatisfy({ $0 == "." || $0 == " " }) { return true }
    }
    return base == "git" && isNTFSShortName(name, "git~1")
  }

  /// Whether `name` is the NTFS 8.3 short name `short`, with NTFS's trailing dots and spaces.
  private static func isNTFSShortName(_ name: String, _ short: String) -> Bool {
    var lowered = Substring(name.lowercased())
    while let last = lowered.last, last == "." || last == " " { lowered = lowered.dropLast() }
    return lowered == short || lowered.hasPrefix(short + ":")
  }

  /// Entries sorted the way git requires: by name, with a tree's name compared as if it ended in `/`.
  static func encode(_ entries: [TreeEntry]) -> Data {
    var data = Data()
    for entry in entries.sorted(by: { sortKey($0).lexicographicallyPrecedes(sortKey($1)) }) {
      data.append(contentsOf: Array("\(entry.mode.treeOctal) \(entry.name)".utf8))
      data.append(0)
      data.append(contentsOf: entry.id.bytes)
    }
    return data
  }

  private static func sortKey(_ entry: TreeEntry) -> [UInt8] {
    Array(entry.name.utf8) + (entry.mode == .tree ? [0x2F] : [])
  }
}

/// Compares paths byte by byte, the order of the index and of `git status`.
@inline(__always)
func pathPrecedes(_ lhs: String, _ rhs: String) -> Bool {
  lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
