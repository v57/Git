import Foundation
import Observation

/// Observable state of one repository for a UI: status, branches, stashes and paged history,
/// kept current by a file watcher. Every action refreshes afterwards and reports failures through
/// `error` instead of throwing.
@MainActor @Observable
public final class RepositorySession {
  public enum Activity: Sendable, Hashable {
    case staging, discarding, committing, fetching, pulling, pushing, switchingBranch, stashing,
      continuing, aborting, reverting, resetting, tagging, merging, resolving, checkingOut,
      cherryPicking

    public var title: String {
      switch self {
      case .staging: "Staging…"
      case .discarding: "Discarding…"
      case .committing: "Committing…"
      case .fetching: "Fetching…"
      case .pulling: "Pulling…"
      case .pushing: "Pushing…"
      case .switchingBranch: "Switching branch…"
      case .stashing: "Stashing…"
      case .continuing: "Continuing…"
      case .aborting: "Aborting…"
      case .reverting: "Reverting…"
      case .resetting: "Resetting…"
      case .tagging: "Tagging…"
      case .merging: "Merging…"
      case .resolving: "Resolving…"
      case .checkingOut: "Checking out…"
      case .cherryPicking: "Cherry-picking…"
      }
    }
  }

  /// A failure to show to the user.
  public struct Failure: Identifiable, Sendable {
    public let id = UUID()
    public var title: String
    public var message: String
  }

  public let repository: Repository
  public private(set) var status: WorkingTreeStatus?
  public private(set) var branches: [Branch] = []
  public private(set) var stashes: [Stash] = []
  public private(set) var tags: [Tag] = []
  /// Lines added and removed per changed file, keyed by `FileChange.id`.
  public private(set) var lineCounts: [FileChange.ID: LineCounts] = [:]
  public private(set) var remotes: [String] = []
  public private(set) var worktrees: [Worktree] = []
  /// The commit HEAD points to.
  public private(set) var headCommit: Commit?
  /// Commits on HEAD that aren't pushed (to the upstream, or to any remote without one).
  public private(set) var unpushed: Set<String> = []
  public private(set) var lastFetched: Date?
  public private(set) var commits: [Commit] = []
  /// The branch graph, one row per commit, when the history isn't filtered.
  public private(set) var graph: [GraphRow] = []
  /// What the operation in progress brings in, e.g. the branch being merged.
  public private(set) var operationSource: String?
  public private(set) var hasMoreCommits = true
  public private(set) var isLoadingCommits = false
  public private(set) var isRefreshing = false
  /// Increments after every refresh, so views can reload diffs that may have changed.
  public private(set) var revision = 0
  public private(set) var activity: Activity?
  /// The latest `--progress` line of a running fetch, pull or push.
  public private(set) var progress: String?
  public var failure: Failure?

  /// Which commits the history shows; changing it reloads the first page.
  public var logQuery = LogQuery() {
    didSet { if logQuery != oldValue { Task { await reloadHistory() } } }
  }

  public static let pageSize = 200

  private var watcher: RepositoryWatcher?
  private var refreshAgain = false
  private var refreshTask: Task<Void, Never>?
  private var historyGeneration = 0
  private var historyKey: String?

  public init(repository: Repository) {
    self.repository = repository
  }

  public convenience init(url: URL) {
    self.init(repository: Repository(url: url))
  }

  public var localBranches: [Branch] { branches.filter { !$0.isRemote } }
  public var remoteBranches: [Branch] { branches.filter(\.isRemote) }
  public var currentBranch: Branch? { branches.first(where: \.isCurrent) }
  /// Local branches with commits the current branch doesn't have.
  public var branchesAheadOfHead: [Branch] {
    localBranches.filter { !$0.isCurrent && ($0.aheadOfHead ?? 0) > 0 }
  }
  /// The branch checked out in another worktree, if any.
  public func worktree(for branch: Branch) -> Worktree? {
    worktrees.first { $0.branch == branch.name && !$0.isCurrent }
  }
  public var isBusy: Bool { activity != nil }

  // MARK: Lifecycle

  /// Loads the state and starts watching the file system.
  public func activate() async {
    if watcher == nil {
      var paths = [repository.url]
      if let gitDir = try? await repository.gitDirectory(),
        !gitDir.path.hasPrefix(repository.url.path + "/")
      {
        paths.append(gitDir)
      }
      let watcher = RepositoryWatcher(paths: paths) { [weak self] in
        Task { @MainActor in await self?.refresh() }
      }
      watcher.start()
      self.watcher = watcher
    }
    await refresh()
  }

  /// Stops watching. The loaded state stays.
  public func deactivate() {
    watcher?.stop()
    watcher = nil
  }

  // MARK: Refresh

  /// Reloads status, branches, stashes and remotes; reloads history when HEAD or refs moved.
  /// A call during a refresh asks for one more pass and returns when that pass is done, so the
  /// state is current when any caller resumes.
  public func refresh() async {
    if let refreshTask {
      refreshAgain = true
      await refreshTask.value
      return
    }
    let task = Task {
      repeat {
        refreshAgain = false
        await load()
      } while refreshAgain
    }
    refreshTask = task
    isRefreshing = true
    await task.value
    refreshTask = nil
    isRefreshing = false
  }

  private func load() async {
    let repository = repository
    async let status = repository.status()
    async let branches = repository.branches()
    async let stashes = repository.stashes()
    async let remotes = repository.remotes()
    async let worktrees = repository.worktrees()
    async let unpushed = repository.unpushedCommits()
    async let head = repository.log(limit: 1)
    async let lastFetched = repository.lastFetchDate()
    async let tags = repository.tags()
    do {
      let newStatus = try await status
      if let operation = newStatus.operation {
        if operation != self.status?.operation || operationSource == nil {
          operationSource = await repository.operationSource(operation)
        }
      } else {
        operationSource = nil
      }
      self.status = newStatus
      let untracked = newStatus.unstaged.filter { $0.kind == .untracked }.map(\.path)
      if let counts = try? await repository.lineCounts(untracked: untracked) {
        var byID: [FileChange.ID: LineCounts] = [:]
        for change in newStatus.staged { byID[change.id] = counts.staged[change.path] }
        for change in newStatus.unstaged { byID[change.id] = counts.unstaged[change.path] }
        lineCounts = byID
      }
      self.tags = (try? await tags) ?? []
      self.branches = (try? await branches) ?? []
      self.stashes = (try? await stashes) ?? []
      self.remotes = (try? await remotes) ?? []
      self.worktrees = (try? await worktrees) ?? []
      self.unpushed = (try? await unpushed) ?? []
      self.headCommit = (try? await head)?.first
      self.lastFetched = await lastFetched
      revision += 1
      let key = ([newStatus.headOID ?? "-"] + self.branches.map { "\($0.refName)=\($0.sha)" })
        .joined(separator: ",")
      if key != historyKey {
        historyKey = key
        await reloadHistory()
      }
    } catch {
      _ = try? await branches
      _ = try? await stashes
      _ = try? await remotes
      _ = try? await worktrees
      _ = try? await unpushed
      _ = try? await head
      _ = await lastFetched
      _ = try? await tags
      report(error, title: "Couldn't read the repository")
    }
  }

  // MARK: History

  /// Drops the loaded history and loads the first page again.
  public func reloadHistory() async {
    historyGeneration += 1
    commits = []
    graph = []
    hasMoreCommits = true
    isLoadingCommits = false
    await loadMoreCommits()
  }

  /// Loads the next page of history.
  public func loadMoreCommits() async {
    guard hasMoreCommits, !isLoadingCommits else { return }
    isLoadingCommits = true
    let generation = historyGeneration
    let skip = commits.count
    do {
      let page = try await repository.log(logQuery, skip: skip, limit: Self.pageSize)
      guard generation == historyGeneration else { return }
      commits += page
      let showsGraph = logQuery.showsGraph
      let all = commits
      let layout = showsGraph ? await Task.detached { CommitGraph.layout(all) }.value : []
      guard generation == historyGeneration else { return }
      graph = layout
      hasMoreCommits = page.count == Self.pageSize && logQuery.searchField != .sha
    } catch {
      guard generation == historyGeneration else { return }
      hasMoreCommits = false
      report(error, title: "Couldn't load history")
    }
    isLoadingCommits = false
  }

  // MARK: Actions

  /// Runs `work` as `activity`, reports a failure, and refreshes. Returns whether it succeeded.
  @discardableResult
  public func perform(
    _ activity: Activity, failureTitle: String,
    _ work: @Sendable @escaping (Repository) async throws -> Void
  ) async -> Bool {
    self.activity = activity
    progress = nil
    defer {
      self.activity = nil
      progress = nil
    }
    var succeeded = true
    do {
      try await work(repository)
    } catch {
      succeeded = false
      report(error, title: failureTitle)
    }
    await refresh()
    return succeeded
  }

  private func progressHandler() -> @Sendable (String) -> Void {
    { [weak self] line in Task { @MainActor in self?.progress = line } }
  }

  public func stage(_ changes: [FileChange]) async {
    let paths = changes.map(\.path)
    await perform(.staging, failureTitle: "Couldn't stage") { try await $0.stage(paths) }
  }

  public func unstage(_ changes: [FileChange]) async {
    let paths = changes.flatMap { [$0.originalPath, $0.path].compactMap { $0 } }
    await perform(.staging, failureTitle: "Couldn't unstage") { try await $0.unstage(paths) }
  }

  public func stageAll() async {
    await perform(.staging, failureTitle: "Couldn't stage") { try await $0.stageAll() }
  }

  public func unstageAll() async {
    await perform(.staging, failureTitle: "Couldn't unstage") { try await $0.unstageAll() }
  }

  public func discard(_ changes: [FileChange]) async {
    await perform(.discarding, failureTitle: "Couldn't discard changes") {
      try await $0.discard(changes)
    }
  }

  public func stageLines(_ lines: Set<Int>, of diff: FileDiff) async {
    await perform(.staging, failureTitle: "Couldn't stage lines") {
      try await $0.stageLines(lines, of: diff)
    }
  }

  public func unstageLines(_ lines: Set<Int>, of diff: FileDiff) async {
    await perform(.staging, failureTitle: "Couldn't unstage lines") {
      try await $0.unstageLines(lines, of: diff)
    }
  }

  public func discardLines(_ lines: Set<Int>, of diff: FileDiff) async {
    await perform(.discarding, failureTitle: "Couldn't discard lines") {
      try await $0.discardLines(lines, of: diff)
    }
  }

  @discardableResult
  public func commit(message: String, amend: Bool = false) async -> Bool {
    await perform(.committing, failureTitle: "Couldn't commit") {
      try await $0.commit(message: message, amend: amend)
    }
  }

  @discardableResult
  public func fetch() async -> Bool {
    let progress = progressHandler()
    return await perform(.fetching, failureTitle: "Couldn't fetch") {
      try await $0.fetch(progress: progress)
    }
  }

  @discardableResult
  public func pull() async -> Bool {
    let progress = progressHandler()
    return await perform(.pulling, failureTitle: "Couldn't pull") {
      try await $0.pull(progress: progress)
    }
  }

  @discardableResult
  public func push(force: Bool = false) async -> Bool {
    let progress = progressHandler()
    return await perform(.pushing, failureTitle: "Couldn't push") {
      try await $0.push(force: force, progress: progress)
    }
  }

  public func switchTo(_ branch: Branch) async {
    await perform(.switchingBranch, failureTitle: "Couldn't switch to \(branch.name)") {
      try await $0.switchTo(branch)
    }
  }

  @discardableResult
  public func createBranch(_ name: String, from startPoint: String? = nil, checkout: Bool = true)
    async -> Bool
  {
    await perform(.switchingBranch, failureTitle: "Couldn't create \(name)") {
      try await $0.createBranch(name, from: startPoint, checkout: checkout)
    }
  }

  public func deleteBranch(_ branch: Branch, force: Bool = false) async {
    await perform(.switchingBranch, failureTitle: "Couldn't delete \(branch.name)") {
      try await $0.deleteBranch(branch.name, force: force)
    }
  }

  public func stash(message: String? = nil, includeUntracked: Bool = true) async {
    await perform(.stashing, failureTitle: "Couldn't stash") {
      try await $0.stash(message: message, includeUntracked: includeUntracked)
    }
  }

  public func applyStash(_ stash: Stash) async {
    await perform(.stashing, failureTitle: "Couldn't apply the stash") {
      try await $0.applyStash(stash)
    }
  }

  public func popStash(_ stash: Stash) async {
    await perform(.stashing, failureTitle: "Couldn't pop the stash") {
      try await $0.popStash(stash)
    }
  }

  public func dropStash(_ stash: Stash) async {
    await perform(.stashing, failureTitle: "Couldn't drop the stash") {
      try await $0.dropStash(stash)
    }
  }

  public func merge(_ branch: Branch) async {
    await perform(.merging, failureTitle: "Couldn't merge \(branch.name)") {
      try await $0.merge(branch)
    }
  }

  public func revert(_ commit: Commit) async {
    await perform(.reverting, failureTitle: "Couldn't revert \(commit.shortID)") {
      try await $0.revert(commit)
    }
  }

  public func checkout(_ commit: Commit) async {
    await perform(.checkingOut, failureTitle: "Couldn't check out \(commit.shortID)") {
      try await $0.checkout(commit)
    }
  }

  public func cherryPick(_ commit: Commit) async {
    await perform(.cherryPicking, failureTitle: "Couldn't cherry-pick \(commit.shortID)") {
      try await $0.cherryPick(commit)
    }
  }

  public func reset(to commit: Commit, mode: Repository.ResetMode = .mixed) async {
    await perform(.resetting, failureTitle: "Couldn't reset to \(commit.shortID)") {
      try await $0.reset(to: commit.id, mode: mode)
    }
  }

  /// Undoes the last commit, keeping its changes staged. Returns its message, or `nil` on failure.
  public func undoLastCommit() async -> String? {
    let box = MessageBox()
    let succeeded = await perform(.resetting, failureTitle: "Couldn't undo the commit") {
      box.message = try await $0.undoLastCommit()
    }
    return succeeded ? box.message : nil
  }

  @discardableResult
  public func createTag(_ name: String, at commit: Commit?, message: String? = nil) async -> Bool {
    await perform(.tagging, failureTitle: "Couldn't create tag \(name)") {
      try await $0.createTag(name, at: commit?.id, message: message)
    }
  }

  /// Whether `commit` is on HEAD but not pushed yet.
  public func isUnpushed(_ commit: Commit) -> Bool { unpushed.contains(commit.id) }

  public func continueOperation() async {
    guard let operation = status?.operation else { return }
    await perform(.continuing, failureTitle: "Couldn't continue") {
      try await $0.continueOperation(operation)
    }
  }

  public func abortOperation() async {
    guard let operation = status?.operation else { return }
    await perform(.aborting, failureTitle: "Couldn't abort") {
      try await $0.abortOperation(operation)
    }
  }

  // MARK: Conflicts

  /// Writes the resolved text of a conflicted file and marks it resolved.
  @discardableResult
  public func resolveConflict(_ change: FileChange, with text: String) async -> Bool {
    let path = change.path
    return await perform(.resolving, failureTitle: "Couldn't resolve \(change.fileName)") {
      try await $0.resolveConflict(path, with: text)
    }
  }

  /// Resolves a conflicted file with one side's whole version (deleting it if that side did).
  @discardableResult
  public func resolveConflict(_ change: FileChange, taking side: ConflictSide) async -> Bool {
    let path = change.path
    return await perform(.resolving, failureTitle: "Couldn't resolve \(change.fileName)") {
      try await $0.resolveConflict(path, taking: side)
    }
  }

  // MARK: Errors

  public func report(_ error: any Error, title: String) {
    if error is CancellationError { return }
    let message = (error as? GitError)?.message ?? error.localizedDescription
    failure = Failure(title: title, message: message)
  }
}

private final class MessageBox: @unchecked Sendable {
  var message: String?
}
