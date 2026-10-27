import CryptoKit
import Foundation

/// Stores a pack as it arrives and indexes it, as `git index-pack` does: the bytes go to a file while each object's
/// end is found by inflating it (zlib reports where its stream stops), whole objects are hashed on the way, and
/// `finish` resolves the deltas, then writes `pack-<sha>.pack` and its version 2 `.idx`.
final class PackIndexer {
  private let packDirectory: URL
  private let temporaryURL: URL
  private let handle: FileHandle
  private let progress: (@Sendable (String) -> Void)?

  private enum State { case header, entryHeader, inflating, trailer }
  private var state = State.header
  private var pending: [UInt8] = []
  private var packHasher = Insecure.SHA1()
  private var offset = 0
  private var trailer: [UInt8] = []
  private(set) var objectCount = 0
  private var lastPercent = -1

  struct Entry {
    var offset: Int
    var type: Int
    var size: Int
    var base: PackFile.Base
    var dataOffset: Int
    var crc: UInt32
    /// Known at once for whole objects, after `finish` for deltas.
    var id: ObjectID?
  }

  private(set) var entries: [Entry] = []
  private var current: Entry?
  private var objectHasher: Insecure.SHA1?
  private let inflater: StreamingInflater

  init(packDirectory: URL, progress: (@Sendable (String) -> Void)?) throws {
    self.packDirectory = packDirectory
    self.progress = progress
    try FileManager.default.createDirectory(at: packDirectory, withIntermediateDirectories: true)
    temporaryURL = packDirectory.appendingPathComponent("tmp_pack_\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil),
      let handle = FileHandle(forWritingAtPath: temporaryURL.path)
    else { throw GitEngineError(.fileSystem, "Couldn't create a file for the received objects.") }
    self.handle = handle
    inflater = try StreamingInflater()
  }

  deinit {
    try? handle.close()
    try? FileManager.default.removeItem(at: temporaryURL)
  }

  /// Takes the next bytes of the pack.
  func append<Bytes: Collection<UInt8>>(_ bytes: Bytes) throws {
    guard !bytes.isEmpty else { return }
    let chunk = Data(bytes)
    try handle.write(contentsOf: chunk)
    var buffer = pending
    pending = []
    buffer.append(contentsOf: chunk)
    try buffer.withUnsafeBytes { try parse($0) }
  }

  private func consumed(_ bytes: UnsafeRawBufferPointer) {
    packHasher.update(bufferPointer: bytes)
    offset += bytes.count
  }

  private func parse(_ buffer: UnsafeRawBufferPointer) throws {
    var position = 0
    while position < buffer.count {
      let rest = UnsafeRawBufferPointer(rebasing: buffer[position...])
      switch state {
      case .header:
        guard rest.count >= 12 else {
          pending = Array(rest)
          return
        }
        guard Array(rest[0..<4]) == Array("PACK".utf8), [2, 3].contains(PackIndex.uint32(rest, 4)) else {
          throw GitEngineError.network("The server sent something other than a pack.")
        }
        objectCount = Int(PackIndex.uint32(rest, 8))
        consumed(UnsafeRawBufferPointer(rebasing: rest[0..<12]))
        position += 12
        state = objectCount == 0 ? .trailer : .entryHeader
        entries.reserveCapacity(objectCount)
      case .entryHeader:
        guard let header = PackVarint.entryHeader(rest, at: 0) else {
          pending = Array(rest)
          return
        }
        var length = header.length
        var base = PackFile.Base.none
        switch header.type {
        case PackFile.ofsDelta:
          guard let distance = PackVarint.offset(rest, at: length) else {
            pending = Array(rest)
            return
          }
          guard distance.value <= offset else { throw GitEngineError.network("The received pack is damaged.") }
          base = .offset(offset - distance.value)
          length += distance.length
        case PackFile.refDelta:
          guard rest.count >= length + 20 else {
            pending = Array(rest)
            return
          }
          base = .id(ObjectID(rest, at: length))
          length += 20
        case 1...4:
          var hasher = Insecure.SHA1()
          hasher.update(data: GitObject.header(ObjectType(rawValue: header.type)!, size: header.size))
          objectHasher = hasher
        default:
          throw GitEngineError.network("The received pack has an unknown object type.")
        }
        let headerBytes = UnsafeRawBufferPointer(rebasing: rest[0..<length])
        current = Entry(
          offset: offset, type: header.type, size: header.size, base: base, dataOffset: offset + length,
          crc: Zlib.crc32(0, headerBytes))
        if header.type >= PackFile.ofsDelta { objectHasher = nil }
        consumed(headerBytes)
        position += length
        inflater.reset()
        state = .inflating
      case .inflating:
        var hasher = objectHasher
        let (used, ended) = try inflater.feed(rest) { output in hasher?.update(bufferPointer: output) }
        objectHasher = hasher
        let usedBytes = UnsafeRawBufferPointer(rebasing: rest[0..<used])
        current!.crc = Zlib.crc32(current!.crc, usedBytes)
        consumed(usedBytes)
        position += used
        guard ended else {
          if used == 0 { throw GitEngineError.network("The received pack is damaged.") }
          continue
        }
        var entry = current!
        entry.id = objectHasher.map { ObjectID(bytes: Array($0.finalize())) }
        entries.append(entry)
        current = nil
        report("Receiving objects", entries.count, objectCount, bytes: true)
        state = entries.count == objectCount ? .trailer : .entryHeader
      case .trailer:
        let take = min(20 - trailer.count, rest.count)
        trailer += rest[0..<take]
        position += take
        if take == 0 { return }
      }
    }
  }

  private func report(_ phase: String, _ done: Int, _ total: Int, bytes: Bool = false) {
    guard let progress, total > 0 else { return }
    let percent = done * 100 / total
    guard percent != lastPercent else { return }
    lastPercent = percent
    let padding = String(repeating: " ", count: max(0, 3 - String(percent).count))
    var line = "\(phase): \(padding)\(percent)% (\(done)/\(total))"
    if bytes { line += String(format: ", %.2f MiB", Double(offset) / 1_048_576) }
    if done == total { line += ", done." }
    progress(line)
  }

  /// Checks the pack's checksum, resolves its deltas (bases outside the pack come from `store`), writes the pack
  /// and its index into the pack folder and returns the index's URL; `nil` for an empty pack.
  @discardableResult
  func finish(store: ObjectStore?) throws -> URL? {
    try handle.synchronize()
    try handle.close()
    guard state == .trailer, trailer.count == 20 else {
      throw GitEngineError.network("The received pack is incomplete.")
    }
    let checksum = Array(packHasher.finalize())
    guard checksum == trailer else { throw GitEngineError.network("The received pack's checksum is wrong.") }
    guard objectCount > 0 else { return nil }
    try resolveDeltas(store: store)

    let name = "pack-" + ObjectID(bytes: checksum).hex
    let packURL = packDirectory.appendingPathComponent(name + ".pack")
    let indexURL = packDirectory.appendingPathComponent(name + ".idx")
    if FileManager.default.fileExists(atPath: indexURL.path) { return indexURL }
    try? FileManager.default.removeItem(at: packURL)
    try FileManager.default.moveItem(at: temporaryURL, to: packURL)
    try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: packURL.path)
    let index = Self.indexData(entries.map { ($0.id!, $0.offset, $0.crc) }, packChecksum: checksum)
    let temporaryIndex = packDirectory.appendingPathComponent("tmp_idx_\(UUID().uuidString)")
    try index.write(to: temporaryIndex)
    try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: temporaryIndex.path)
    try FileManager.default.moveItem(at: temporaryIndex, to: indexURL)
    return indexURL
  }

  /// Gives every delta its ID by applying it to its base, depth first from each whole object, so only one chain of
  /// bases is in memory at a time.
  private func resolveDeltas(store: ObjectStore?) throws {
    let pack = try Data(contentsOf: temporaryURL, options: .alwaysMapped)
    var byOffset: [Int: Int] = [:]
    var childrenByOffset: [Int: [Int]] = [:]
    var childrenByID: [ObjectID: [Int]] = [:]
    for (number, entry) in entries.enumerated() {
      byOffset[entry.offset] = number
      switch entry.base {
      case .offset(let base): childrenByOffset[base, default: []].append(number)
      case .id(let base): childrenByID[base, default: []].append(number)
      case .none: break
      }
    }
    let deltaCount = entries.count { $0.id == nil }
    guard deltaCount > 0 else { return }
    var resolved = 0
    lastPercent = -1

    func inflate(_ entry: Entry) throws -> Data {
      try pack.withUnsafeBytes { buffer in
        try Zlib.inflate(UnsafeRawBufferPointer(rebasing: buffer[entry.dataOffset...]), expectedSize: entry.size).data
      }
    }
    func children(of offset: Int?, id: ObjectID) -> [Int] {
      (offset.flatMap { childrenByOffset[$0] } ?? []) + (childrenByID[id] ?? [])
    }
    struct Frame {
      var data: Data
      var type: ObjectType
      var children: [Int]
      var next = 0
    }
    func walk(from root: Frame) throws {
      var stack = [root]
      while !stack.isEmpty {
        let top = stack.count - 1
        guard stack[top].next < stack[top].children.count else {
          stack.removeLast()
          continue
        }
        let child = stack[top].children[stack[top].next]
        stack[top].next += 1
        guard entries[child].id == nil else { continue }
        let data = try Delta.apply(inflate(entries[child]), to: stack[top].data)
        let type = stack[top].type
        let id = GitObject.id(type, data)
        entries[child].id = id
        resolved += 1
        report("Resolving deltas", resolved, deltaCount)
        let grandchildren = children(of: entries[child].offset, id: id)
        if !grandchildren.isEmpty { stack.append(Frame(data: data, type: type, children: grandchildren)) }
      }
    }

    for number in entries.indices where entries[number].base.isWhole {
      let entry = entries[number]
      let list = children(of: entry.offset, id: entry.id!)
      guard !list.isEmpty, let type = ObjectType(rawValue: entry.type) else { continue }
      try walk(from: Frame(data: try inflate(entry), type: type, children: list))
    }
    // Deltas against objects the repository already has (a thin pack).
    if resolved < deltaCount, let store {
      for (base, list) in childrenByID where list.contains(where: { entries[$0].id == nil }) {
        guard let object = try store.readIfPresent(base) else { continue }
        try walk(from: Frame(data: object.data, type: object.type, children: list))
      }
    }
    guard resolved == deltaCount else {
      throw GitEngineError.network("The received pack refers to objects the repository doesn't have.")
    }
  }

  /// A version 2 pack index for `(id, offset, crc)` entries.
  static func indexData(_ objects: [(id: ObjectID, offset: Int, crc: UInt32)], packChecksum: [UInt8]) -> Data {
    let sorted = objects.sorted { $0.id < $1.id }
    var data = Data([0xFF, 0x74, 0x4F, 0x63, 0, 0, 0, 2])
    func append(_ value: UInt32) { data.append(contentsOf: bigEndianBytes(value)) }
    var fanout = [UInt32](repeating: 0, count: 256)
    for object in sorted { fanout[Int(object.id.firstByte)] += 1 }
    var total: UInt32 = 0
    for slot in 0..<256 {
      total += fanout[slot]
      append(total)
    }
    for object in sorted { data.append(contentsOf: object.id.bytes) }
    for object in sorted { append(object.crc) }
    var large: [Int] = []
    for object in sorted {
      if object.offset < 0x8000_0000 {
        append(UInt32(object.offset))
      } else {
        append(0x8000_0000 | UInt32(large.count))
        large.append(object.offset)
      }
    }
    for offset in large {
      append(UInt32(offset >> 32))
      append(UInt32(offset & 0xFFFF_FFFF))
    }
    data.append(contentsOf: packChecksum)
    data.append(contentsOf: Insecure.SHA1.hash(data: data))
    return data
  }
}

extension PackFile.Base {
  var isWhole: Bool {
    if case .none = self { return true }
    return false
  }
}
