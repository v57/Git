import Foundation

/// `.git/objects`: loose objects and packs. One store serves one operation and isn't shared between tasks; it caches
/// parsed commits and recently used delta bases.
final class ObjectStore {
  let directory: URL
  private var packs: [PackFile]?
  private var commits: [ObjectID: CommitObject] = [:]
  private var baseCache: [Int: GitObject] = [:]
  private var baseCacheSize = 0
  private static let baseCacheLimit = 48 << 20

  init(directory: URL) {
    self.directory = directory
  }

  /// The packs, opened on first use.
  private func loadedPacks() throws -> [PackFile] {
    if let packs { return packs }
    let packDirectory = directory.appendingPathComponent("pack")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: packDirectory.path)) ?? []
    let opened = try names.filter { $0.hasSuffix(".idx") }.sorted().compactMap { name -> PackFile? in
      let url = packDirectory.appendingPathComponent(name)
      // A pack being written has its index last; skip an index without its pack.
      guard FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("pack").path)
      else { return nil }
      return try PackFile(index: PackIndex(url: url))
    }
    packs = opened
    return opened
  }

  /// Forgets the open packs, after a fetch added one.
  func reloadPacks() {
    packs = nil
    baseCache = [:]
    baseCacheSize = 0
  }

  private func looseURL(_ id: ObjectID) -> URL {
    let hex = id.hex
    return directory.appendingPathComponent(String(hex.prefix(2))).appendingPathComponent(String(hex.dropFirst(2)))
  }

  func contains(_ id: ObjectID) -> Bool {
    id == .emptyTree || isStored(id)
  }

  /// Whether a pack or loose file holds `id` (the empty tree included only when stored).
  func isStored(_ id: ObjectID) -> Bool {
    if let packs = try? loadedPacks(), packs.contains(where: { $0.index.offset(of: id) != nil }) { return true }
    return FileManager.default.fileExists(atPath: looseURL(id).path)
  }

  func read(_ id: ObjectID) throws -> GitObject {
    guard let object = try readIfPresent(id) else { throw GitEngineError.missingObject(id) }
    return object
  }

  func readIfPresent(_ id: ObjectID) throws -> GitObject? {
    for (number, pack) in try loadedPacks().enumerated() {
      if let offset = pack.index.offset(of: id) { return try read(pack, number: number, at: offset) }
    }
    if let compressed = try? Data(contentsOf: looseURL(id)) {
      return try parseLoose(Zlib.inflate(compressed))
    }
    if id == .emptyTree { return GitObject(type: .tree, data: Data()) }
    return nil
  }

  private func parseLoose(_ data: Data) throws -> GitObject {
    guard let nul = data.firstIndex(of: 0), let space = data[..<nul].firstIndex(of: 0x20),
      let type = ObjectType(name: String(decoding: data[data.startIndex..<space], as: UTF8.self)),
      let size = Int(String(decoding: data[(space + 1)..<nul], as: UTF8.self)), data.endIndex - nul - 1 == size
    else { throw GitEngineError.corrupt("A loose object is damaged.") }
    return GitObject(type: type, data: Data(data[(nul + 1)...]))
  }

  private func read(_ pack: PackFile, number: Int, at offset: Int) throws -> GitObject {
    let key = number << 44 | offset
    if let cached = baseCache[key] { return cached }
    let entry = try pack.entry(at: offset)
    let object: GitObject
    switch entry.base {
    case .none:
      guard let type = ObjectType(rawValue: entry.type) else {
        throw GitEngineError.corrupt("A pack entry is damaged.")
      }
      object = GitObject(type: type, data: try pack.inflate(entry))
    case .offset(let baseOffset):
      let base = try read(pack, number: number, at: baseOffset)
      object = GitObject(type: base.type, data: try Delta.apply(pack.inflate(entry), to: base.data))
    case .id(let baseID):
      let base = try read(baseID)
      object = GitObject(type: base.type, data: try Delta.apply(pack.inflate(entry), to: base.data))
    }
    if entry.type >= PackFile.ofsDelta || object.data.count < 1 << 20 { remember(object, key) }
    return object
  }

  private func remember(_ object: GitObject, _ key: Int) {
    if baseCacheSize + object.data.count > Self.baseCacheLimit {
      baseCache = [:]
      baseCacheSize = 0
    }
    baseCache[key] = object
    baseCacheSize += object.data.count
  }

  /// Writes a loose object unless the store already has it.
  @discardableResult
  func write(_ type: ObjectType, _ data: Data) throws -> ObjectID {
    let id = GitObject.id(type, data)
    if isStored(id) { return id }
    let url = looseURL(id)
    var raw = GitObject.header(type, size: data.count)
    raw.append(data)
    let compressed = try Zlib.deflate(raw)
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let temporary = url.deletingLastPathComponent().appendingPathComponent("tmp_obj_\(UUID().uuidString)")
      try compressed.write(to: temporary)
      // Objects are read-only, as git leaves them.
      try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: temporary.path)
      if rename(temporary.path, url.path) != 0 {
        try? FileManager.default.removeItem(at: temporary)
        if !FileManager.default.fileExists(atPath: url.path) {
          throw GitEngineError(.fileSystem, "Couldn't write object \(id.hex).")
        }
      }
    } catch {
      throw GitEngineError.file(error, url.path)
    }
    return id
  }

  /// IDs starting with `prefix` (at least four hex digits).
  func ids(withPrefix prefix: String) throws -> [ObjectID] {
    let prefix = prefix.lowercased()
    guard prefix.count >= 4, prefix.count <= 40, prefix.allSatisfy(\.isHexDigit) else { return [] }
    if prefix.count == 40, let id = ObjectID(hex: prefix) { return contains(id) ? [id] : [] }
    var found = Set<ObjectID>()
    for pack in try loadedPacks() { found.formUnion(pack.index.ids(withPrefix: prefix)) }
    let folder = directory.appendingPathComponent(String(prefix.prefix(2)))
    for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
      let hex = String(prefix.prefix(2)) + name
      if hex.hasPrefix(prefix), let id = ObjectID(hex: hex) { found.insert(id) }
    }
    return Array(found)
  }

  // MARK: Typed reads

  func commit(_ id: ObjectID) throws -> CommitObject {
    if let cached = commits[id] { return cached }
    let object = try read(id)
    guard object.type == .commit else { throw GitEngineError.corrupt("\(id.hex) isn't a commit.") }
    let commit = try CommitObject(object.data)
    commits[id] = commit
    return commit
  }

  func tree(_ id: ObjectID) throws -> [TreeEntry] {
    let object = try read(id)
    guard object.type == .tree else { throw GitEngineError.corrupt("\(id.hex) isn't a tree.") }
    return try TreeObject.parse(object.data)
  }

  /// Follows tags to what they point to, then commits to their trees when `toTree` is set.
  func peel(_ id: ObjectID) throws -> (id: ObjectID, type: ObjectType) {
    var current = id
    for _ in 0..<32 {
      let object = try read(current)
      guard object.type == .tag else { return (current, object.type) }
      current = try TagObject(object.data).object
    }
    throw GitEngineError.corrupt("A tag chain is too long.")
  }

  /// The commit `id` names, peeling tags.
  func commitID(peeling id: ObjectID) throws -> ObjectID {
    let peeled = try peel(id)
    guard peeled.type == .commit else { throw GitEngineError.notFound("\(id.hex) isn't a commit.") }
    return peeled.id
  }

  /// Every file under a tree, keyed by path (gitlinks included, trees left out).
  func files(inTree id: ObjectID?, prefix: String = "") throws -> [String: TreeFile] {
    var result: [String: TreeFile] = [:]
    guard let id else { return result }
    try collectFiles(id, prefix: prefix, into: &result)
    return result
  }

  private func collectFiles(_ id: ObjectID, prefix: String, into result: inout [String: TreeFile]) throws {
    for entry in try tree(id) {
      let path = prefix + entry.name
      if entry.mode == .tree {
        try collectFiles(entry.id, prefix: path + "/", into: &result)
      } else {
        result[path] = TreeFile(mode: entry.mode, id: entry.id)
      }
    }
  }

  /// The entry at `path` inside a tree.
  func entry(at path: String, inTree id: ObjectID) throws -> TreeEntry? {
    var tree = id
    let components = path.split(separator: "/")
    for (number, component) in components.enumerated() {
      guard let entry = try self.tree(tree).first(where: { $0.name == component }) else { return nil }
      if number == components.count - 1 { return entry }
      guard entry.mode == .tree else { return nil }
      tree = entry.id
    }
    return nil
  }
}
