import Foundation
import Observation

/// Observable state of one repository for a UI: status, branches, stashes and paged history,
/// kept current by a file watcher. Every action refreshes afterwards and reports failures through
/// `error` instead of throwing.
@MainActor @Observable
public final class RepositorySession {
  public enum Activity: Sendable, Hashable {
    case staging, discarding, committing, fetching, pulling, pushing, switchingBranch, stashing,
      continuing, aborting

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
  public private(set) var remotes: [String] = []
  public private(set) var commits: [Commit] = []
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
    do {
      let newStatus = try await status
      self.status = newStatus
      self.branches = (try? await branches) ?? []
      self.stashes = (try? await stashes) ?? []
      self.remotes = (try? await remotes) ?? []
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
      report(error, title: "Couldn't read the repository")
    }
  }

  // MARK: History

  /// Drops the loaded history and loads the first page again.
  public func reloadHistory() async {
    historyGeneration += 1
    commits = []
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

  // MARK: Errors

  public func report(_ error: any Error, title: String) {
    if error is CancellationError { return }
    let message = (error as? GitError)?.message ?? error.localizedDescription
    failure = Failure(title: title, message: message)
  }
}
