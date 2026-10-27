import Foundation
import GitKit

extension LocalRepository {
  /// The branch, its upstream and divergence, and the staged, unstaged and untracked files (each untracked file
  /// listed, like `git status --untracked-files=all`). Staged renames are found as git finds them.
  @concurrent public func status() async throws -> WorkingTreeStatus {
    let context = try context()
    var status = WorkingTreeStatus()
    let head = try context.head()
    status.branch = head.branchName
    let headCommit = try context.headCommit()
    status.headOID = headCommit?.hex
    if let branch = head.branchName, let upstream = context.upstream(of: branch) {
      status.upstream = upstream.remote == "." ? shortName(upstream.mergeRef) : upstream.shortName
      if let headCommit, let tracking = context.refs.resolve(upstream.trackingRef) {
        let divergence = try RevWalk.divergence(context.objects, headCommit, tracking)
        status.ahead = divergence.ahead
        status.behind = divergence.behind
      }
    }
    status.operation = operation(in: context.gitDirectory)

    var index = try context.readIndex()
    let conflicted = Set(index.entries.filter { $0.stage != 0 }.map(\.path))
    status.conflicted = conflicted.sorted(by: pathPrecedes).map { path in
      FileChange(path: path, kind: .conflicted, area: .conflicted, conflict: conflictType(path, index))
    }

    // Staged: HEAD against the index.
    let headFiles = try context.headFiles()
    var indexFiles: [String: TreeFile] = [:]
    for entry in index.entries where entry.stage == 0 && !entry.isIntentToAdd {
      indexFiles[entry.path] = TreeFile(mode: entry.mode, id: entry.id)
    }
    let staged = TreeDiff.changes(
      old: headFiles.filter { !conflicted.contains($0.key) }, new: indexFiles, renames: true, store: context.objects)
    status.staged = staged.map { change in
      FileChange(
        path: change.path, originalPath: change.originalPath, kind: change.kind, area: .staged,
        isSubmodule: change.new?.mode == .gitlink || change.old?.mode == .gitlink)
    }

    // Unstaged: the index against the working tree, then untracked files.
    let scan = try WorktreeScanner(context: context).scan(index)
    status.unstaged =
      scan.changes.map { FileChange(path: $0.path, kind: $0.kind, area: .unstaged) }
      + scan.untracked.map { FileChange(path: $0, kind: .untracked, area: .unstaged) }
    // Remember files found unchanged, so the next status needn't hash them again (as git status does).
    if !scan.refreshed.isEmpty {
      index.apply(updated: scan.refreshed)
      try? context.writeIndex(index)
    }
    return status
  }

  /// A merge, rebase, cherry-pick or revert that git left in progress.
  func operation(in gitDirectory: URL) -> RepositoryOperation? {
    func exists(_ name: String) -> Bool {
      FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent(name).path)
    }
    if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
    if exists("MERGE_HEAD") { return .merge }
    if exists("CHERRY_PICK_HEAD") { return .cherryPick }
    if exists("REVERT_HEAD") { return .revert }
    return nil
  }

  /// How the conflict stages of `path` disagree: stage 1 is the base, 2 ours, 3 theirs.
  private func conflictType(_ path: String, _ index: GitIndex) -> ConflictType? {
    let stages = Set(index.entries.filter { $0.path == path }.map(\.stage))
    switch (stages.contains(1), stages.contains(2), stages.contains(3)) {
    case (true, true, true): return .bothModified
    case (false, true, true): return .bothAdded
    case (true, false, false): return .bothDeleted
    case (false, true, false): return .addedByUs
    case (false, false, true): return .addedByThem
    case (true, false, true): return .deletedByUs
    case (true, true, false): return .deletedByThem
    default: return nil
    }
  }
}
