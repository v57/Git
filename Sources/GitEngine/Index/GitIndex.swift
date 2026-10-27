import CryptoKit
import Foundation

/// One entry of `.git/index`: a path's staged blob and the file's stat data when it was last checked.
struct IndexEntry: Sendable {
  var stat: FileStat
  var mode: FileMode
  var id: ObjectID
  var path: String
  /// 0, or 1–3 for the sides of a conflict.
  var stage: Int = 0
  var assumeValid = false
  /// Version 3 flags (skip-worktree, intent-to-add), kept as read.
  var extendedFlags: UInt16 = 0

  init(path: String, mode: FileMode, id: ObjectID, stat: FileStat = FileStat(), stage: Int = 0) {
    self.path = path
    self.mode = mode
    self.id = id
    self.stat = stat
    self.stage = stage
  }

  var skipsWorktree: Bool { extendedFlags & 0x4000 != 0 }
  var isIntentToAdd: Bool { extendedFlags & 0x2000 != 0 }
}

/// `.git/index` (the staging area). Reads versions 2, 3 and 4; writes version 2 (or 3 when an entry needs its
/// extended flags), without extensions: a stale TREE cache would be worse than none.
struct GitIndex {
  var entries: [IndexEntry] = []
  /// The index file's modification time when it was read: files changed in the same instant must be hashed.
  var fileMtime: UInt64 = 0

  init() {}

  init(url: URL) throws {
    guard let data = try? Data(contentsOf: url) else { return }
    fileMtime = FileStat.of(url.path)?.mtime ?? 0
    entries = try data.withUnsafeBytes { try Self.parse($0) }
  }

  private static func uint32(_ buffer: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
    PackIndex.uint32(buffer, offset)
  }

  private static func parse(_ buffer: UnsafeRawBufferPointer) throws -> [IndexEntry] {
    guard buffer.count >= 32, Array(buffer[0..<4]) == Array("DIRC".utf8) else {
      throw GitEngineError.corrupt("The index file is damaged.")
    }
    let version = uint32(buffer, 4)
    guard (2...4).contains(version) else {
      throw GitEngineError.corrupt("The index file is version \(version), which the engine doesn't read.")
    }
    let count = Int(uint32(buffer, 8))
    var entries: [IndexEntry] = []
    entries.reserveCapacity(count)
    var position = 12
    var previousPath: [UInt8] = []
    let end = buffer.count - 20
    for _ in 0..<count {
      let start = position
      guard position + 62 <= end else { throw GitEngineError.corrupt("The index file is truncated.") }
      var stat = FileStat()
      stat.ctimeSeconds = uint32(buffer, position)
      stat.ctimeNanoseconds = uint32(buffer, position + 4)
      stat.mtimeSeconds = uint32(buffer, position + 8)
      stat.mtimeNanoseconds = uint32(buffer, position + 12)
      stat.device = uint32(buffer, position + 16)
      stat.inode = uint32(buffer, position + 20)
      let mode = uint32(buffer, position + 24)
      stat.uid = uint32(buffer, position + 28)
      stat.gid = uint32(buffer, position + 32)
      stat.size = uint32(buffer, position + 36)
      let id = ObjectID(buffer, at: position + 40)
      let flags = UInt16(buffer[position + 60]) << 8 | UInt16(buffer[position + 61])
      position += 62
      var extended: UInt16 = 0
      if flags & 0x4000 != 0 {
        guard version >= 3, position + 2 <= end else { throw GitEngineError.corrupt("The index file is damaged.") }
        extended = UInt16(buffer[position]) << 8 | UInt16(buffer[position + 1])
        position += 2
      }
      var path: [UInt8]
      if version == 4 {
        guard let strip = PackVarint.offset(buffer, at: position), strip.value <= previousPath.count else {
          throw GitEngineError.corrupt("The index file is damaged.")
        }
        position += strip.length
        guard let nul = buffer[position..<end].firstIndex(of: 0) else {
          throw GitEngineError.corrupt("The index file is damaged.")
        }
        path = Array(previousPath.prefix(previousPath.count - strip.value)) + Array(buffer[position..<nul])
        position = nul + 1
      } else {
        guard let nul = buffer[position..<end].firstIndex(of: 0) else {
          throw GitEngineError.corrupt("The index file is damaged.")
        }
        path = Array(buffer[position..<nul])
        // Entries are padded with 1–8 NULs to a multiple of 8 bytes.
        position = start + ((nul - start) / 8 + 1) * 8
      }
      previousPath = path
      var entry = IndexEntry(
        path: String(decoding: path, as: UTF8.self), mode: FileMode(raw: mode), id: id, stat: stat,
        stage: Int(flags >> 12) & 3)
      entry.stat.mode = mode
      entry.assumeValid = flags & 0x8000 != 0
      entry.extendedFlags = extended
      entries.append(entry)
    }
    // Extensions follow; a split index keeps its entries elsewhere.
    while position + 8 <= end {
      let signature = String(decoding: buffer[position..<position + 4], as: UTF8.self)
      if signature == "link" {
        throw GitEngineError.corrupt("The repository uses a split index, which the engine doesn't read.")
      }
      position += 8 + Int(uint32(buffer, position + 4))
    }
    return entries
  }

  /// Sorts the entries by path, then stage, as the file requires.
  mutating func sort() {
    entries.sort { lhs, rhs in
      lhs.path == rhs.path ? lhs.stage < rhs.stage : pathPrecedes(lhs.path, rhs.path)
    }
  }

  func encoded() -> Data {
    let version: UInt32 = entries.contains { $0.extendedFlags != 0 } ? 3 : 2
    var data = Data("DIRC".utf8)
    func append(_ value: UInt32) { data.append(contentsOf: bigEndianBytes(value)) }
    append(version)
    append(UInt32(entries.count))
    for entry in entries {
      let start = data.count
      let stat = entry.stat
      for value in [
        stat.ctimeSeconds, stat.ctimeNanoseconds, stat.mtimeSeconds, stat.mtimeNanoseconds, stat.device, stat.inode,
        entry.mode.rawValue, stat.uid, stat.gid, stat.size,
      ] {
        append(value)
      }
      data.append(contentsOf: entry.id.bytes)
      let path = Array(entry.path.utf8)
      var flags = UInt16(min(path.count, 0xFFF)) | UInt16(entry.stage & 3) << 12
      if entry.assumeValid { flags |= 0x8000 }
      if entry.extendedFlags != 0 { flags |= 0x4000 }
      data.append(contentsOf: [UInt8(flags >> 8), UInt8(flags & 0xFF)])
      if entry.extendedFlags != 0 {
        data.append(contentsOf: [UInt8(entry.extendedFlags >> 8), UInt8(entry.extendedFlags & 0xFF)])
      }
      data.append(contentsOf: path)
      let length = data.count - start
      data.append(contentsOf: [UInt8](repeating: 0, count: 8 - length % 8))
    }
    data.append(contentsOf: Insecure.SHA1.hash(data: data))
    return data
  }

  func write(to url: URL) throws {
    var sorted = self
    sorted.sort()
    try LockFile.write(sorted.encoded(), to: url)
  }

  // MARK: Lookup

  /// Stage-0 entries by path.
  func byPath() -> [String: IndexEntry] {
    var result: [String: IndexEntry] = [:]
    for entry in entries where entry.stage == 0 { result[entry.path] = entry }
    return result
  }

  var hasConflicts: Bool { entries.contains { $0.stage != 0 } }

  /// Replaces every entry (conflict stages too) for the paths of `updated` and `removed` in one pass.
  mutating func apply(updated: [IndexEntry], removed: Set<String> = []) {
    guard !updated.isEmpty || !removed.isEmpty else { return }
    var touched = removed
    for entry in updated { touched.insert(entry.path) }
    entries.removeAll { touched.contains($0.path) }
    entries += updated
    sort()
  }
}
