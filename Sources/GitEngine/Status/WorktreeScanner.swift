import Foundation
import GitKit

/// Compares the working tree with the index: changed and deleted tracked files, and untracked files (each one listed,
/// like `--untracked-files=all`), honoring the ignore rules.
struct WorktreeScanner {
  let context: GitContext

  struct Result {
    /// Tracked files that differ from the index, sorted by path.
    var changes: [(path: String, kind: ChangeKind)] = []
    var untracked: [String] = []
    /// Entries whose file was unchanged but whose stat data was stale: worth writing back to the index.
    var refreshed: [IndexEntry] = []
  }

  /// Scans everything, or only paths equal to or under `pathspecs`.
  func scan(_ index: GitIndex, pathspecs: [String]? = nil, includeUntracked: Bool = true) throws -> Result {
    var result = Result()
    let trustExecutable = context.trustsExecutableBit
    func wanted(_ path: String) -> Bool {
      guard let pathspecs else { return true }
      return pathspecs.contains { $0.isEmpty || path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
    for entry in index.entries where entry.stage == 0 && wanted(entry.path) {
      guard entry.mode != .gitlink, !entry.skipsWorktree, !entry.assumeValid else { continue }
      // `git add -N`: tracked, nothing staged yet.
      if entry.isIntentToAdd {
        result.changes.append((entry.path, .added))
        continue
      }
      switch try check(entry, trustExecutable: trustExecutable, indexMtime: index.fileMtime) {
      case .clean: break
      case .refreshed(let refreshed): result.refreshed.append(refreshed)
      case .changed(let kind): result.changes.append((entry.path, kind))
      }
    }
    if includeUntracked {
      let ignore = IgnoreRules(worktree: context.worktree, gitDirectory: context.gitDirectory)
      var tracked = Set<String>()
      var trackedFolders = Set<String>()
      for entry in index.entries {
        tracked.insert(entry.path)
        var path = entry.path
        while let slash = path.lastIndex(of: "/") {
          path = String(path[..<slash])
          guard trackedFolders.insert(path).inserted else { break }
        }
      }
      // Folders outside the pathspecs are entered only on the way to one.
      func folderWanted(_ path: String) -> Bool {
        guard let pathspecs else { return true }
        return pathspecs.contains { $0.isEmpty || $0.hasPrefix(path + "/") || wanted(path) }
      }
      walk(
        "", ignore: ignore, tracked: tracked, trackedFolders: trackedFolders, wanted: wanted,
        folderWanted: folderWanted, into: &result.untracked)
    }
    return result
  }

  enum Check {
    case clean
    case refreshed(IndexEntry)
    case changed(ChangeKind)
  }

  /// Whether a tracked file still matches its index entry, hashing it only when its stat data says it may not.
  func check(_ entry: IndexEntry, trustExecutable: Bool, indexMtime: UInt64) throws -> Check {
    guard let stat = FileStat.of(context.url(entry.path).path), !stat.isDirectory else { return .changed(.deleted) }
    let mode = stat.fileMode(trustExecutableBit: trustExecutable, previous: entry.mode)
    if mode == .symlink && entry.mode != .symlink && context.supportsSymlinks { return .changed(.typeChanged) }
    if entry.mode == .symlink && mode != .symlink && context.supportsSymlinks { return .changed(.typeChanged) }
    if entry.mode.isFile, mode != entry.mode { return .changed(.modified) }
    let old = entry.stat
    let statMatches =
      old.mtimeSeconds == stat.mtimeSeconds && old.mtimeNanoseconds == stat.mtimeNanoseconds
      && old.ctimeSeconds == stat.ctimeSeconds && old.ctimeNanoseconds == stat.ctimeNanoseconds
      && old.size == stat.size && old.inode == stat.inode
    // Racy git: a file changed in the same instant the index was written may look unchanged.
    if statMatches && stat.mtime < indexMtime { return .clean }
    if !statMatches && old.size != stat.size && entry.mode.isFile && old.size != 0 { return .changed(.modified) }
    let data = try context.readWorktreeFile(entry.path, stat: stat)
    guard GitObject.id(.blob, data) == entry.id else { return .changed(.modified) }
    if statMatches { return .clean }
    var refreshed = entry
    refreshed.stat = stat
    return .refreshed(refreshed)
  }

  /// Lists untracked files under `folder` (`""` or ending in `/`), skipping ignored ones and not entering ignored
  /// folders. A folder holding another repository is listed as `folder/`, as git does.
  private func walk(
    _ folder: String, ignore: IgnoreRules, tracked: Set<String>, trackedFolders: Set<String>,
    wanted: (String) -> Bool, folderWanted: (String) -> Bool, into untracked: inout [String]
  ) {
    let base = context.url(folder).path
    guard let directory = opendir(base) else { return }
    var names: [(String, Bool)] = []
    while let item = readdir(directory) {
      let name = withUnsafeBytes(of: item.pointee.d_name) { buffer in
        #if canImport(Darwin)
          String(decoding: buffer.prefix(Int(item.pointee.d_namlen)), as: UTF8.self)
        #else
          // glibc's dirent has no name length: the name ends at its NUL.
          String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        #endif
      }
      if name == "." || name == ".." || name == ".git" { continue }
      var isDirectory = Int32(item.pointee.d_type) == DT_DIR
      if Int32(item.pointee.d_type) == DT_UNKNOWN { isDirectory = FileStat.of(base + "/" + name)?.isDirectory == true }
      names.append((name, isDirectory))
    }
    closedir(directory)
    names.sort { pathPrecedes($0.0, $1.0) }
    for (name, isDirectory) in names {
      let path = folder + name
      if isDirectory {
        // A submodule, an ignored folder (tracked files in it are checked through the index), or a folder off
        // the pathspecs.
        if tracked.contains(path) || !folderWanted(path) || ignore.isIgnored(path, isDirectory: true) { continue }
        if !trackedFolders.contains(path), FileStat.of(context.url(path).path + "/.git") != nil {
          if wanted(path) { untracked.append(path + "/") }
          continue
        }
        walk(
          path + "/", ignore: ignore, tracked: tracked, trackedFolders: trackedFolders, wanted: wanted,
          folderWanted: folderWanted, into: &untracked)
      } else {
        if tracked.contains(path) || !wanted(path) || ignore.isIgnored(path, isDirectory: false) { continue }
        untracked.append(path)
      }
    }
  }
}
