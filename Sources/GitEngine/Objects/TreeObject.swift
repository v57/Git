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
        entries.append(TreeEntry(name: name, mode: FileMode(raw: mode), id: ObjectID(buffer, at: nul + 1)))
        position = nul + 21
      }
      return entries
    }
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
