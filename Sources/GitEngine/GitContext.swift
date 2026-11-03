import Foundation
import GitKit

/// Everything one operation needs from a repository: its folders, objects, refs and config. Each operation makes
/// its own, so nothing is shared between tasks.
final class GitContext {
  let worktree: URL
  /// This working tree's folder: `.git`, or where a linked worktree's or a submodule's `.git` file points.
  let gitDirectory: URL
  /// What a linked worktree shares with the main repository (objects, refs, config): `gitDirectory` otherwise.
  let commonDirectory: URL
  let objects: ObjectStore
  let refs: RefStore
  private(set) var config: GitConfig
  /// Everything git reads here where the app has git to ask (`git config --list`: the user's and the system's too).
  private var inherited: GitConfig?

  init(worktree: URL, settings: [GitSetting]? = nil) throws {
    self.worktree = worktree
    let dotGit = worktree.appendingPathComponent(".git", isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
      throw GitEngineError(.notARepository, "\(worktree.lastPathComponent) isn't a git repository.")
    }
    if isDirectory.boolValue {
      gitDirectory = dotGit
    } else {
      guard let text = try? String(contentsOf: worktree.appendingPathComponent(".git"), encoding: .utf8),
        text.hasPrefix("gitdir:")
      else { throw GitEngineError(.notARepository, "\(worktree.lastPathComponent) isn't a git repository.") }
      gitDirectory = Self.resolve(String(text.dropFirst(7)), from: worktree)
    }
    guard FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent("HEAD").path) else {
      throw GitEngineError(.notARepository, "\(worktree.lastPathComponent) isn't a git repository.")
    }
    if let text = try? String(contentsOf: gitDirectory.appendingPathComponent("commondir"), encoding: .utf8) {
      commonDirectory = Self.resolve(text, from: gitDirectory)
    } else {
      commonDirectory = gitDirectory
    }
    objects = ObjectStore(directory: commonDirectory.appendingPathComponent("objects"))
    refs = RefStore(gitDirectory: gitDirectory, commonDirectory: commonDirectory)
    config = GitConfig(url: commonDirectory.appendingPathComponent("config"))
    inherited = settings.map(GitConfig.init(settings:))
    let named = inherited ?? config
    if let name = named.value("user.name"), let email = named.value("user.email") {
      refs.identity = GitSignature(name: name, email: email)
    }
  }

  /// A path in a `.git` or `commondir` file, relative to the folder holding the file.
  private static func resolve(_ text: String, from folder: URL) -> URL {
    let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
    return url.standardizedFileURL
  }

  /// What git would read for a key: every config file where the app could ask git, `.git/config` otherwise.
  var settings: GitConfig { inherited ?? config }

  var configURL: URL { commonDirectory.appendingPathComponent("config") }
  var indexURL: URL { gitDirectory.appendingPathComponent("index") }

  func updateConfig(_ change: (inout GitConfig) throws -> Void) throws {
    // Reread under the lock so a concurrent change isn't lost.
    let lock = try LockFile(configURL)
    var fresh = GitConfig(url: configURL)
    do {
      try change(&fresh)
      try lock.commit(Data(fresh.text.utf8))
    } catch {
      lock.cancel()
      throw error
    }
    config = fresh
    if var merged = inherited {
      try change(&merged)
      inherited = merged
    }
  }

  /// `core.filemode`: whether the executable bit in the working tree means anything.
  var trustsExecutableBit: Bool { settings.bool("core.filemode", default: true) }
  var supportsSymlinks: Bool { settings.bool("core.symlinks", default: true) }

  func readIndex() throws -> GitIndex { try GitIndex(url: indexURL) }

  func writeIndex(_ index: GitIndex) throws { try index.write(to: indexURL) }

  // MARK: HEAD

  func head() throws -> Head { try refs.head() }

  /// The commit HEAD points to, or `nil` on an unborn branch.
  func headCommit() throws -> ObjectID? {
    switch try head() {
    case .detached(let id): return id
    case .branch(let ref): return refs.resolve(ref)
    }
  }

  func headTree() throws -> ObjectID? {
    guard let commit = try headCommit() else { return nil }
    return try objects.commit(commit).tree
  }

  func headFiles() throws -> [String: TreeFile] {
    try objects.files(inTree: headTree())
  }

  /// Points the current branch (or a detached HEAD) at `id`.
  func moveHead(to id: ObjectID, expected: ObjectID?, message: String) throws {
    switch try head() {
    case .branch(let ref): try refs.update(ref, to: id, expected: expected ?? .zero, message: message)
    case .detached: try refs.update("HEAD", to: id, expected: expected, message: message)
    }
  }

  // MARK: Revisions

  /// A commit from a name: a full or abbreviated ID, HEAD, a branch, remote branch or tag, optionally followed by
  /// `~n` or `^n`.
  func resolveCommit(_ revision: String) throws -> ObjectID {
    var base = revision[...]
    var steps: [(first: Bool, count: Int)] = []
    // Peel trailing ~n / ^n suffixes.
    while let marker = base.lastIndex(where: { $0 == "~" || $0 == "^" }) {
      let number = base[base.index(after: marker)...]
      guard number.allSatisfy(\.isNumber) else { break }
      let count = number.isEmpty ? 1 : Int(number) ?? 1
      steps.insert((base[marker] == "~", count), at: 0)
      base = base[..<marker]
    }
    guard var id = try resolveName(String(base)) else {
      throw GitEngineError.notFound("There's no commit named “\(revision)”.")
    }
    id = try objects.commitID(peeling: id)
    for step in steps {
      if step.first {
        for _ in 0..<step.count {
          guard let parent = try objects.commit(id).parents.first else {
            throw GitEngineError.notFound("“\(revision)” goes past the first commit.")
          }
          id = parent
        }
      } else if step.count > 0 {
        let parents = try objects.commit(id).parents
        guard step.count <= parents.count else {
          throw GitEngineError.notFound("“\(revision)” has no such parent.")
        }
        id = parents[step.count - 1]
      }
    }
    return id
  }

  private func resolveName(_ name: String) throws -> ObjectID? {
    if name == "HEAD" || name == "@" { return try headCommit() }
    if let id = ObjectID(hex: name) { return id }
    for candidate in [name, "refs/\(name)", "refs/tags/\(name)", "refs/heads/\(name)", "refs/remotes/\(name)"] {
      if let id = refs.resolve(candidate) { return id }
    }
    let matches = try objects.ids(withPrefix: name)
    if matches.count > 1 { throw GitEngineError.notFound("“\(name)” matches more than one object.") }
    return matches.first
  }

  // MARK: Working-tree files

  func url(_ path: String) -> URL { worktree.appendingPathComponent(path) }

  /// A working-tree file's contents as git stores them: a symlink's target, or the file's bytes.
  func readWorktreeFile(_ path: String, stat: FileStat? = nil) throws -> Data {
    let fullPath = url(path).path
    if (stat ?? FileStat.of(fullPath))?.isSymlink == true, supportsSymlinks {
      let target = try FileManager.default.destinationOfSymbolicLink(atPath: fullPath)
      return Data(target.utf8)
    }
    do {
      return try Data(contentsOf: url(path), options: .mappedIfSafe)
    } catch {
      throw GitEngineError.file(error, path)
    }
  }

  /// Writes a blob to the working tree as a file or symlink with `mode`, replacing what's there, and returns the
  /// new file's stat.
  @discardableResult
  func writeWorktreeFile(_ path: String, mode: FileMode, data: Data) throws -> FileStat {
    let target = url(path)
    let fileManager = FileManager.default
    do {
      try createParentFolders(of: path)
      if let existing = FileStat.of(target.path) {
        if existing.isDirectory { try fileManager.removeItem(at: target) } else { unlink(target.path) }
      }
      if mode == .symlink, supportsSymlinks {
        try fileManager.createSymbolicLink(
          atPath: target.path, withDestinationPath: String(decoding: data, as: UTF8.self))
      } else {
        guard fileManager.createFile(atPath: target.path, contents: data) else {
          throw GitEngineError(.fileSystem, "Couldn't write \(path).")
        }
        let permissions = mode == .executable ? 0o755 : 0o644
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
      }
    } catch {
      throw GitEngineError.file(error, path)
    }
    guard let stat = FileStat.of(target.path) else { throw GitEngineError(.fileSystem, "Couldn't write \(path).") }
    return stat
  }

  /// Creates the folders above `path`, removing files that are in the way (they were checked before).
  private func createParentFolders(of path: String) throws {
    var folder = worktree
    for component in path.split(separator: "/").dropLast() {
      folder.appendPathComponent(String(component))
      if let stat = FileStat.of(folder.path), !stat.isDirectory { unlink(folder.path) }
      if FileStat.of(folder.path) == nil {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      }
    }
  }

  /// Removes a working-tree file and then the folders it leaves empty.
  func removeWorktreeFile(_ path: String) {
    let target = url(path)
    if let stat = FileStat.of(target.path) {
      if stat.isDirectory { try? FileManager.default.removeItem(at: target) } else { unlink(target.path) }
    }
    var folder = target.deletingLastPathComponent().standardizedFileURL
    let root = worktree.standardizedFileURL.path
    while folder.path.count > root.count, rmdir(folder.path) == 0 {
      folder = folder.deletingLastPathComponent()
    }
  }
}
