import Foundation
import GitKit

extension LocalRepository {
  /// Stages `paths` (files or folders) as `git add -A` does: changed and new files are added, deleted ones removed
  /// from the index.
  @concurrent public func stage(_ paths: [String]) async throws {
    guard !paths.isEmpty else { return }
    try stage(pathspecs: paths.map(normalized))
  }

  @concurrent public func stageAll() async throws {
    try stage(pathspecs: [""])
  }

  private func normalized(_ path: String) -> String {
    var path = path
    while path.hasSuffix("/") { path.removeLast() }
    return path == "." ? "" : path
  }

  private func stage(pathspecs: [String]) throws {
    let context = try context()
    var index = try context.readIndex()
    let scan = try WorktreeScanner(context: context).scan(index, pathspecs: pathspecs)
    let current = index.byPath()
    var updated = scan.refreshed
    var removed = Set<String>()
    for (path, kind) in scan.changes {
      if kind == .deleted {
        removed.insert(path)
      } else {
        updated.append(try stagedEntry(path, context, previous: current[path]?.mode))
      }
    }
    // Nested repositories (`folder/`) aren't added.
    for path in scan.untracked where !path.hasSuffix("/") {
      updated.append(try stagedEntry(path, context, previous: nil))
    }
    var listed = Set(updated.map(\.path)).union(removed)
    // Conflicted files take whatever the working tree has.
    for entry in index.entries
    where entry.stage != 0 && !listed.contains(entry.path) && matches(entry.path, pathspecs) {
      listed.insert(entry.path)
      if FileStat.of(context.url(entry.path).path) != nil {
        updated.append(try stagedEntry(entry.path, context, previous: entry.mode))
      } else {
        removed.insert(entry.path)
      }
    }
    // A file named directly is added even when ignored.
    let tracked = Set(index.entries.map(\.path))
    for path in pathspecs where !path.isEmpty && !tracked.contains(path) && !listed.contains(path) {
      if let stat = FileStat.of(context.url(path).path), !stat.isDirectory {
        updated.append(try stagedEntry(path, context, previous: nil))
      }
    }
    index.apply(updated: updated, removed: removed)
    try context.writeIndex(index)
  }

  private func matches(_ path: String, _ pathspecs: [String]) -> Bool {
    pathspecs.contains { $0.isEmpty || path == $0 || path.hasPrefix($0 + "/") }
  }

  /// Hashes a working-tree file into the object store and returns its index entry.
  private func stagedEntry(_ path: String, _ context: GitContext, previous: FileMode?) throws -> IndexEntry {
    guard let stat = FileStat.of(context.url(path).path) else {
      throw GitEngineError.notFound("\(path) doesn't exist.")
    }
    let mode = stat.fileMode(trustExecutableBit: context.trustsExecutableBit, previous: previous)
    let id = try context.objects.write(.blob, context.readWorktreeFile(path, stat: stat))
    return IndexEntry(path: path, mode: mode, id: id, stat: stat)
  }

  /// Resets the index entries of `paths` (files or folders) to HEAD's, removing ones HEAD doesn't have.
  @concurrent public func unstage(_ paths: [String]) async throws {
    guard !paths.isEmpty else { return }
    try unstage(pathspecs: paths.map(normalized))
  }

  @concurrent public func unstageAll() async throws {
    try unstage(pathspecs: [""])
  }

  private func unstage(pathspecs: [String]) throws {
    let context = try context()
    var index = try context.readIndex()
    let head = try context.headFiles()
    let current = index.byPath()
    var updated: [IndexEntry] = []
    var removed = Set<String>()
    for entry in index.entries where matches(entry.path, pathspecs) && head[entry.path] == nil {
      removed.insert(entry.path)
    }
    for (path, file) in head where matches(path, pathspecs) {
      var entry = IndexEntry(path: path, mode: file.mode, id: file.id)
      // Keeping the stat data of an entry that already matches saves hashing the file again.
      if let old = current[path], old.id == file.id, old.mode == file.mode { entry.stat = old.stat }
      updated.append(entry)
    }
    index.apply(updated: updated, removed: removed)
    try context.writeIndex(index)
  }

  /// Throws away working-tree changes: tracked files are restored from the index, untracked files deleted.
  @concurrent public func discard(_ changes: [FileChange]) async throws {
    guard !changes.isEmpty else { return }
    let context = try context()
    var index = try context.readIndex()
    let entries = index.byPath()
    var updated: [IndexEntry] = []
    for change in changes {
      if change.kind == .untracked {
        let target = context.url(change.path)
        guard FileStat.of(target.path) != nil else { continue }
        do {
          try FileManager.default.removeItem(at: target)
        } catch {
          throw GitEngineError.file(error, change.path)
        }
        continue
      }
      guard let entry = entries[change.path] else { continue }
      if entry.mode == .gitlink { continue }
      let data = try context.objects.read(entry.id).data
      var restored = entry
      restored.stat = try context.writeWorktreeFile(change.path, mode: entry.mode, data: data)
      updated.append(restored)
    }
    index.apply(updated: updated)
    try context.writeIndex(index)
  }

  /// Commits the index on the current branch (or the detached HEAD) and returns the new commit's ID. Works on an
  /// unborn branch; refuses when nothing is staged.
  @concurrent public func commit(message: String, author: GitSignature) async throws -> String {
    let context = try context()
    let index = try context.readIndex()
    guard !index.hasConflicts else {
      throw GitEngineError.refused("Resolve the conflicts before committing.")
    }
    let message = Self.cleanedMessage(message)
    guard !message.isEmpty else { throw GitEngineError.refused("Write a commit message first.") }
    let entries = index.entries.filter { $0.stage == 0 && !$0.isIntentToAdd }
    let tree = try TreeBuilder.write(entries, to: context.objects)
    let parent = try context.headCommit()
    if let parent {
      guard try context.objects.commit(parent).tree != tree else {
        throw GitEngineError.refused("Nothing is staged. Stage the changes to commit first.")
      }
    } else if entries.isEmpty {
      throw GitEngineError.refused("Nothing is staged. Stage the files to commit first.")
    }
    let commit = CommitObject(
      tree: tree, parents: parent.map { [$0] } ?? [], author: author, committer: author, message: message)
    let id = try context.objects.write(.commit, commit.encoded)
    context.refs.identity = author
    try context.moveHead(
      to: id, expected: parent, message: "commit\(parent == nil ? " (initial)" : ""): \(commit.subject)")
    return id.hex
  }

  /// Trailing whitespace off every line, no leading or trailing blank lines, runs of blank lines made one, and a
  /// final newline, like git's default cleanup (comment lines are kept: there's no editor template here).
  static func cleanedMessage(_ message: String) -> String {
    var lines: [String] = []
    let text = message.replacingOccurrences(of: "\r\n", with: "\n")
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      var line = String(line)
      while let last = line.last, last == " " || last == "\t" || last == "\r" { line.removeLast() }
      if line.isEmpty, lines.last?.isEmpty ?? true { continue }
      lines.append(line)
    }
    while lines.last?.isEmpty == true { lines.removeLast() }
    return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
  }
}

/// Writes the tree objects for a list of index entries.
enum TreeBuilder {
  static func write(_ entries: [IndexEntry], to store: ObjectStore) throws -> ObjectID {
    try write(entries.map { (Substring($0.path), $0) }[...], store)
  }

  private static func write(_ entries: ArraySlice<(Substring, IndexEntry)>, _ store: ObjectStore) throws -> ObjectID {
    var treeEntries: [TreeEntry] = []
    var folders: [String: [(Substring, IndexEntry)]] = [:]
    var folderOrder: [String] = []
    for (path, entry) in entries {
      if let slash = path.firstIndex(of: "/") {
        let folder = String(path[..<slash])
        if folders[folder] == nil { folderOrder.append(folder) }
        folders[folder, default: []].append((path[path.index(after: slash)...], entry))
      } else {
        treeEntries.append(TreeEntry(name: String(path), mode: entry.mode, id: entry.id))
      }
    }
    for folder in folderOrder {
      treeEntries.append(TreeEntry(name: folder, mode: .tree, id: try write(folders[folder]![...], store)))
    }
    return try store.write(.tree, TreeObject.encode(treeEntries))
  }
}
