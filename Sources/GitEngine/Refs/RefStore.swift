import Foundation

/// Where HEAD points.
enum Head: Equatable {
  /// A branch (`refs/heads/main`), which may not exist yet (an unborn branch).
  case branch(String)
  case detached(ObjectID)

  var branchRef: String? {
    if case .branch(let ref) = self { return ref }
    return nil
  }

  /// `main` for `refs/heads/main`.
  var branchName: String? {
    branchRef.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 }
  }
}

/// Loose refs, `packed-refs` and symbolic refs under a `.git` directory.
final class RefStore {
  let gitDirectory: URL
  /// Who appears in reflog entries.
  var identity: GitSignature?
  private var packedCache: [String: (id: ObjectID, peeled: ObjectID?)]?

  init(gitDirectory: URL) {
    self.gitDirectory = gitDirectory
  }

  enum Value: Equatable {
    case id(ObjectID)
    case symbolic(String)
  }

  private func url(_ name: String) -> URL { gitDirectory.appendingPathComponent(name) }

  /// `packed-refs`: `<id> <name>` lines, each optionally followed by `^<peeled id>`.
  private func packed() -> [String: (id: ObjectID, peeled: ObjectID?)] {
    if let packedCache { return packedCache }
    var refs: [String: (id: ObjectID, peeled: ObjectID?)] = [:]
    var last: String?
    if let text = try? String(contentsOf: url("packed-refs"), encoding: .utf8) {
      for line in text.split(separator: "\n") {
        if line.hasPrefix("#") { continue }
        if line.hasPrefix("^"), let last, let peeled = ObjectID(hex: line.dropFirst()) {
          refs[last]?.peeled = peeled
          continue
        }
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let id = ObjectID(hex: parts[0]) else { continue }
        let name = String(parts[1])
        refs[name] = (id, nil)
        last = name
      }
    }
    packedCache = refs
    return refs
  }

  func read(_ name: String) -> Value? {
    if let data = try? Data(contentsOf: url(name)), !isDirectory(url(name)) {
      let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      if text.hasPrefix("ref: ") { return .symbolic(String(text.dropFirst(5))) }
      if let id = ObjectID(hex: text) { return .id(id) }
      return nil
    }
    return packed()[name].map { .id($0.id) }
  }

  private func isDirectory(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
  }

  /// Follows symbolic refs to an ID; `nil` for a missing ref or an unborn branch.
  func resolve(_ name: String) -> ObjectID? {
    var current = name
    for _ in 0..<8 {
      switch read(current) {
      case .id(let id): return id
      case .symbolic(let target): current = target
      case nil: return nil
      }
    }
    return nil
  }

  /// The tag's peeled target when `packed-refs` records it.
  func peeled(_ name: String) -> ObjectID? { packed()[name]?.peeled }

  func head() throws -> Head {
    switch read("HEAD") {
    case .symbolic(let target): return .branch(target)
    case .id(let id): return .detached(id)
    case nil: throw GitEngineError(.notARepository, "The repository's HEAD is missing or damaged.")
    }
  }

  /// Every ref under `prefix` (e.g. `refs/heads/`), loose ones overriding packed ones, sorted by name. Symbolic refs
  /// are resolved; ones that resolve to nothing are left out.
  func list(_ prefix: String) -> [(name: String, id: ObjectID)] {
    var names = Set(packed().keys.filter { $0.hasPrefix(prefix) })
    if let enumerator = FileManager.default.enumerator(atPath: url(prefix).path) {
      while let relative = enumerator.nextObject() as? String {
        guard enumerator.fileAttributes?[.type] as? FileAttributeType != .typeDirectory,
          !relative.hasSuffix(".lock")
        else { continue }
        names.insert(prefix + relative)
      }
    }
    return names.sorted(by: pathPrecedes).compactMap { name in resolve(name).map { (name, $0) } }
  }

  /// Whether `name` is a symbolic ref (e.g. `refs/remotes/origin/HEAD`).
  func isSymbolic(_ name: String) -> Bool {
    if case .symbolic = read(name) { return true }
    return false
  }

  // MARK: Writing

  /// Points `name` at `id`. With `expected`, fails when the ref moved meanwhile (`.zero` means it must not exist).
  func update(_ name: String, to id: ObjectID, expected: ObjectID? = nil, message: String) throws {
    let lock = try LockFile(url(name))
    let old = resolve(name)
    if let expected, (old ?? .zero) != expected {
      lock.cancel()
      throw GitEngineError(.refused, "\(shortName(name)) changed while the operation ran. Try again.")
    }
    try lock.commit(Data((id.hex + "\n").utf8))
    log(name, old: old ?? .zero, new: id, message: message)
    if case .branch(name)? = try? head() { log("HEAD", old: old ?? .zero, new: id, message: message) }
  }

  /// Points HEAD at a commit directly (detached) or at a ref.
  func setSymbolic(_ name: String, to target: String, message: String? = nil) throws {
    let old = resolve(name)
    try LockFile.write(Data("ref: \(target)\n".utf8), to: url(name))
    if let message, let new = resolve(target) { log(name, old: old ?? .zero, new: new, message: message) }
  }

  /// Removes a ref, loose and packed.
  func delete(_ name: String) throws {
    let lock = try LockFile(url(name))
    defer { lock.cancel() }
    if packed()[name] != nil {
      let packedURL = url("packed-refs")
      let text = (try? String(contentsOf: packedURL, encoding: .utf8)) ?? ""
      var lines: [Substring] = []
      var skipping = false
      for line in text.split(separator: "\n") {
        if line.hasPrefix("^") {
          if !skipping { lines.append(line) }
          continue
        }
        skipping = line.split(separator: " ", maxSplits: 1).last.map(String.init) == name
        if !skipping { lines.append(line) }
      }
      try LockFile.write(Data((lines.joined(separator: "\n") + "\n").utf8), to: packedURL)
      packedCache = nil
    }
    try? FileManager.default.removeItem(at: url(name))
    try? FileManager.default.removeItem(at: url("logs/" + name))
    removeEmptyFolders(from: url(name).deletingLastPathComponent(), stoppingAt: url("refs"))
  }

  private func removeEmptyFolders(from folder: URL, stoppingAt root: URL) {
    var folder = folder.standardizedFileURL
    let root = root.standardizedFileURL
    while folder.path.count > root.path.count,
      (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true
    {
      try? FileManager.default.removeItem(at: folder)
      folder = folder.deletingLastPathComponent()
    }
  }

  /// Appends to `logs/<name>` the way git does for branches and HEAD.
  private func log(_ name: String, old: ObjectID, new: ObjectID, message: String) {
    guard name == "HEAD" || name.hasPrefix("refs/heads/") || name.hasPrefix("refs/remotes/") else { return }
    let who = identity ?? GitSignature(name: "GitEngine", email: "")
    let signature = GitSignature(name: who.name, email: who.email, date: .now)
    let line = "\(old.hex) \(new.hex) \(signature.encoded)\t\(message.replacingOccurrences(of: "\n", with: " "))\n"
    let logURL = url("logs/" + name)
    try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: logURL) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    } else {
      try? Data(line.utf8).write(to: logURL)
    }
  }
}

/// `main` for `refs/heads/main`, `origin/main` for `refs/remotes/origin/main`.
func shortName(_ ref: String) -> String {
  for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where ref.hasPrefix(prefix) {
    return String(ref.dropFirst(prefix.count))
  }
  return ref
}
