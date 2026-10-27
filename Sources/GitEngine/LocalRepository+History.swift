import Foundation
import GitKit

extension LocalRepository {
  /// A page of commits reachable from `revision` (HEAD when `nil`), newest first by commit date, with the branches,
  /// remote branches and tags that point at each.
  @concurrent public func log(revision: String? = nil, skip: Int = 0, limit: Int = 200) async throws -> [Commit] {
    let context = try context()
    if revision == nil, try context.headCommit() == nil { return [] }
    let tip = try context.resolveCommit(revision ?? "HEAD")
    let labels = try refLabels(context)
    return try RevWalk.log(context.objects, from: [tip], skip: skip, limit: limit).map { item in
      item.commit.model(id: item.id, refs: labels[item.id] ?? [])
    }
  }

  /// The refs pointing at each commit, ordered as `git log --decorate` shows them: HEAD (or the current branch)
  /// first, then branches, remote branches and tags.
  func refLabels(_ context: GitContext) throws -> [ObjectID: [RefLabel]] {
    var labels: [ObjectID: [RefLabel]] = [:]
    let head = try context.head()
    if case .detached(let id) = head {
      labels[id, default: []].append(RefLabel(name: "HEAD", kind: .head, isCurrent: true))
    }
    for (name, id) in context.refs.list("refs/heads/") {
      let label = RefLabel(name: shortName(name), kind: .localBranch, isCurrent: head.branchRef == name)
      if label.isCurrent { labels[id, default: []].insert(label, at: 0) } else { labels[id, default: []].append(label) }
    }
    for (name, id) in context.refs.list("refs/remotes/") where !context.refs.isSymbolic(name) {
      labels[id, default: []].append(RefLabel(name: shortName(name), kind: .remoteBranch))
    }
    for (name, id) in context.refs.list("refs/tags/") {
      let target = context.refs.peeled(name) ?? (try? context.objects.peel(id).id) ?? id
      labels[target, default: []].append(RefLabel(name: shortName(name), kind: .tag))
    }
    return labels
  }

  /// The files `commit` changed against its first parent (everything, for a root commit), with renames and line
  /// counts.
  @concurrent public func changedFiles(in commit: Commit) async throws -> [CommitFile] {
    let context = try context()
    guard let id = ObjectID(hex: commit.id) else { throw GitEngineError.notFound("\(commit.id) isn't a commit ID.") }
    let object = try context.objects.commit(id)
    let parentTree = try commit.parents.first.flatMap(ObjectID.init(hex:)).map { try context.objects.commit($0).tree }
    let changes = TreeDiff.changes(
      old: try context.objects.files(inTree: parentTree), new: try context.objects.files(inTree: object.tree),
      renames: true, store: context.objects)
    return changes.map { change in
      var lines: LineCounts?
      if change.old?.mode != .gitlink, change.new?.mode != .gitlink {
        let old = change.old.flatMap { try? context.objects.read($0.id).data }
        let new = change.new.flatMap { try? context.objects.read($0.id).data }
        lines = DiffBuilder.lineCounts(old: old, new: new)
      }
      return CommitFile(path: change.path, originalPath: change.originalPath, kind: change.kind, lines: lines)
    }
  }

  /// One file's diff, or `nil` when it has no changes. Unstaged diffs compare the index with the working tree
  /// (untracked files with nothing), staged ones HEAD with the index, and commits their first parent with them.
  @concurrent public func diff(_ target: DiffTarget) async throws -> FileDiff? {
    let context = try context()
    let old: DiffSide?
    let new: DiffSide?
    switch target {
    case .unstaged(let path, true):
      old = nil
      new = try worktreeSide(path, context, previous: nil)
    case .unstaged(let path, false):
      let index = try context.readIndex()
      let entries = index.entries.filter { $0.path == path }
      // A conflicted file compares our side with the working tree.
      guard let entry = entries.first(where: { $0.stage == 0 }) ?? entries.first(where: { $0.stage == 2 }) else {
        return nil
      }
      if entry.mode == .gitlink { return nil }
      old = DiffSide(path: path, mode: entry.mode, data: try context.objects.read(entry.id).data)
      new = try worktreeSide(path, context, previous: entry.mode)
    case .staged(let path, let originalPath):
      let index = try context.readIndex()
      old = try treeSide(originalPath ?? path, tree: context.headTree(), context)
      new = try index.entries.first { $0.path == path && $0.stage == 0 && $0.mode != .gitlink }.map {
        DiffSide(path: path, mode: $0.mode, data: try context.objects.read($0.id).data)
      }
    case .commit(let sha, let parent, let path, let originalPath):
      let commit = try context.resolveCommit(sha)
      let parentTree = try parent.map { try context.objects.commit(context.resolveCommit($0)).tree }
      old = try treeSide(originalPath ?? path, tree: parentTree, context)
      new = try treeSide(path, tree: context.objects.commit(commit).tree, context)
    }
    var similarity: Int?
    if let old, let new, old.path != new.path {
      similarity = RenameDetector.similarity(
        (old.data.count, RenameDetector.chunkCounts(old.data)), (new.data.count, RenameDetector.chunkCounts(new.data)))
    }
    return DiffBuilder.diff(old: old, new: new, similarity: similarity)
  }

  private func worktreeSide(_ path: String, _ context: GitContext, previous: FileMode?) throws -> DiffSide? {
    guard let stat = FileStat.of(context.url(path).path), !stat.isDirectory else { return nil }
    let mode = stat.fileMode(trustExecutableBit: context.trustsExecutableBit, previous: previous)
    return DiffSide(path: path, mode: mode, data: try context.readWorktreeFile(path, stat: stat))
  }

  private func treeSide(_ path: String, tree: ObjectID?, _ context: GitContext) throws -> DiffSide? {
    guard let tree, let entry = try context.objects.entry(at: path, inTree: tree), entry.mode != .tree,
      entry.mode != .gitlink
    else { return nil }
    return DiffSide(path: path, mode: entry.mode, data: try context.objects.read(entry.id).data)
  }

  /// A file's contents in the working tree, the index or a commit; `nil` when it doesn't exist there.
  @concurrent public func contents(of path: String, at revision: FileRevision) async -> Data? {
    guard let context = try? context() else { return nil }
    switch revision {
    case .workingTree:
      return try? Data(contentsOf: context.url(path))
    case .index:
      guard let entry = try? context.readIndex().entries.first(where: { $0.path == path && $0.stage == 0 }) else {
        return nil
      }
      return try? context.objects.read(entry.id).data
    case .commit(let sha):
      guard let commit = try? context.resolveCommit(sha), let tree = try? context.objects.commit(commit).tree,
        let entry = try? context.objects.entry(at: path, inTree: tree), entry.mode != .tree
      else { return nil }
      return try? context.objects.read(entry.id).data
    }
  }
}
