import Foundation
import GitKit

/// Moves the working tree and the index from one tree to another (git's two-way `read-tree -m -u`): files that
/// differ between the trees are written or removed; other files, and changes to them, stay as they are.
struct Checkout {
  let context: GitContext

  /// The files a move changes, checked against local changes.
  struct Plan {
    var old: [String: TreeFile]
    var new: [String: TreeFile]
    var changed: Set<String>
  }

  func move(from oldTree: ObjectID?, to newTree: ObjectID?, index: inout GitIndex) throws {
    try apply(plan(from: oldTree, to: newTree, index: index), to: &index)
  }

  /// Finds what moving from `oldTree` to `newTree` changes; throws when that would lose local changes.
  func plan(from oldTree: ObjectID?, to newTree: ObjectID?, index: GitIndex) throws -> Plan {
    guard !index.hasConflicts else { throw GitEngineError.refused("Resolve the conflicts first.") }
    let old = try context.objects.files(inTree: oldTree)
    let new = try context.objects.files(inTree: newTree)
    var changed = Set<String>()
    for (path, file) in new where old[path] != file { changed.insert(path) }
    for path in old.keys where new[path] == nil { changed.insert(path) }
    let current = index.byPath()
    let scanner = WorktreeScanner(context: context)

    // Refuse before touching anything when local changes would be lost.
    var blocked: [String] = []
    for path in changed {
      let target = new[path]
      let entry = current[path]
      let staged = entry.map { TreeFile(mode: $0.mode, id: $0.id) }
      if staged != old[path] && staged != target {
        blocked.append(path)
        continue
      }
      if !(try worktreeMatches(path, entry: entry, target: target, scanner: scanner, indexMtime: index.fileMtime)) {
        blocked.append(path)
        continue
      }
      // A file where the new tree needs a folder.
      var folder = path
      while let slash = folder.lastIndex(of: "/") {
        folder = String(folder[..<slash])
        if let stat = FileStat.of(context.url(folder).path), !stat.isDirectory, !changed.contains(folder) {
          blocked.append(folder)
        }
      }
    }
    if !blocked.isEmpty {
      let names = blocked.sorted(by: pathPrecedes)
      let list = names.prefix(5).joined(separator: ", ") + (names.count > 5 ? " and \(names.count - 5) more" : "")
      throw GitEngineError.refused(
        "Your changes to \(list) would be overwritten. Commit or discard them first.")
    }
    return Plan(old: old, new: new, changed: changed)
  }

  /// Writes and removes the planned files and updates the index to match.
  func apply(_ plan: Plan, to index: inout GitIndex) throws {
    let (new, changed) = (plan.new, plan.changed)
    let current = index.byPath()
    var updated: [IndexEntry] = []
    var removed = Set<String>()
    // Removals first, so a folder can take a removed file's place.
    for path in changed.sorted(by: pathPrecedes).reversed() where new[path] == nil {
      if current[path] != nil { context.removeWorktreeFile(path) }
      removed.insert(path)
    }
    for path in changed.sorted(by: pathPrecedes) {
      guard let target = new[path] else { continue }
      if target.mode == .gitlink {
        try? FileManager.default.createDirectory(at: context.url(path), withIntermediateDirectories: true)
        updated.append(IndexEntry(path: path, mode: target.mode, id: target.id))
        continue
      }
      let data = try context.objects.read(target.id).data
      let stat = try context.writeWorktreeFile(path, mode: target.mode, data: data)
      updated.append(IndexEntry(path: path, mode: target.mode, id: target.id, stat: stat))
    }
    index.apply(updated: updated, removed: removed)
  }

  /// Whether the working-tree file at `path` can be replaced: it matches the index, or already is the target.
  private func worktreeMatches(
    _ path: String, entry: IndexEntry?, target: TreeFile?, scanner: WorktreeScanner, indexMtime: UInt64
  ) throws -> Bool {
    let stat = FileStat.of(context.url(path).path)
    // Submodules are left alone.
    if entry?.mode == .gitlink || target?.mode == .gitlink { return true }
    if let entry {
      switch try scanner.check(entry, trustExecutable: context.trustsExecutableBit, indexMtime: indexMtime) {
      case .clean, .refreshed: return true
      case .changed(.deleted): return target == nil || stat == nil
      case .changed: break
      }
    } else if stat == nil || target == nil || stat?.isDirectory == true {
      // Nothing there, or an untracked file the switch doesn't touch.
      return stat?.isDirectory != true || target == nil || (try? FileManager.default.contentsOfDirectory(
        atPath: context.url(path).path).isEmpty) == true
    }
    // A changed or untracked file is fine only when it already has the target's contents.
    guard let target, let stat, !stat.isDirectory else { return false }
    let data = try context.readWorktreeFile(path, stat: stat)
    return GitObject.id(.blob, data) == target.id
  }
}
