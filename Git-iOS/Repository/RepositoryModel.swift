import Foundation
import GitEngine
import GitKit
import Observation
import SSHKit

/// Where a repository is: on this device, or on another machine.
enum RepositorySource: Hashable, Identifiable {
  case local(LocalRepository)
  case remote(RemoteRepository)

  var id: String {
    switch self {
    case .local(let repository): "local:" + repository.url.path
    case .remote(let repository): "remote:" + repository.id
    }
  }

  var name: String {
    switch self {
    case .local(let repository): repository.name
    case .remote(let repository): repository.name
    }
  }
}

/// One open repository for the screens: its status, branches and history, loaded from its backend and refreshed
/// after every action, when the app comes back, and (for one on another machine, which can't be watched) every few
/// seconds while it's open. Failures land in `failure` instead of being thrown.
@MainActor @Observable final class RepositoryModel {
  enum Phase: Equatable {
    case connecting(String)
    case ready
    case failed(String)
  }

  /// A failure to show.
  struct Failure: Identifiable {
    let id = UUID()
    var title: String
    var message: String
  }

  let source: RepositorySource
  private(set) var phase: Phase
  private(set) var backend: (any GitBackend)?
  /// The device the repository is on, for one on another machine.
  private(set) var target: RemoteTarget?
  /// The repository's folder there.
  private(set) var path: String?

  private(set) var status: WorkingTreeStatus?
  private(set) var lineCounts: [FileChange.ID: GitKit.LineCounts] = [:]
  private(set) var branches: [Branch] = []
  private(set) var commits: [Commit] = []
  private(set) var hasMoreCommits = true
  private(set) var isLoadingCommits = false
  /// What's running ("Pushing…"), and its latest progress line.
  private(set) var activity: String?
  private(set) var progress: String?
  /// Increments after every refresh, so open diffs reload.
  private(set) var revision = 0
  var failure: Failure?

  static let pageSize = 100

  @ObservationIgnored private var transport: SSHGitTransport?
  @ObservationIgnored private var refreshing = false
  @ObservationIgnored private var refreshAgain = false

  init(source: RepositorySource) {
    self.source = source
    switch source {
    case .local(let repository):
      phase = .ready
      path = repository.url.path
      backend = LocalBackend(repository: repository) { CommitAuthor.signature }
    case .remote(let repository):
      phase = .connecting("Connecting to \(repository.targets.first?.name ?? "the device")")
    }
  }

  var features: GitFeatures { backend?.features ?? [] }
  var isRemote: Bool { if case .remote = source { true } else { false } }
  var isBusy: Bool { activity != nil }
  var currentBranch: Branch? { branches.first(where: \.isCurrent) }
  var localBranches: [Branch] { branches.filter { !$0.isRemote } }
  var remoteBranches: [Branch] { branches.filter(\.isRemote) }
  var hasRemote: Bool { !remoteBranches.isEmpty || status?.upstream != nil }

  // MARK: Opening

  /// Connects (for one on another machine: the first device that answers) and loads everything.
  func open() async {
    if case .remote(let repository) = source, backend == nil {
      var failures: [String] = []
      for target in repository.targets {
        phase = .connecting("Connecting to \(target.name)")
        do {
          try await connect(to: target)
          break
        } catch {
          failures.append("\(target.name): \(Self.describe(error))")
        }
      }
      guard backend != nil else {
        phase = .failed(failures.joined(separator: "\n"))
        return
      }
    }
    phase = .ready
    await refresh()
    await reloadHistory()
  }

  private func connect(to target: RemoteTarget) async throws {
    let transport = SSHGitTransport(
      target: target, login: { try await MainActor.run { try RemoteRepositories.login(for: target) } },
      onNewHostKey: { fingerprint in Task { @MainActor in RemoteRepositories.trust(fingerprint, for: target) } })
    let output = try await transport.shell(
      "cd \(SSHGitTransport.path(target.directory)) && exec git rev-parse --show-toplevel")
    guard output.status == 0 else {
      transport.close()
      let message = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      throw SSHGitTransport.RemoteError.failed(
        message.contains("not a git repository") ? "\(target.directory) isn’t a Git repository." : message)
    }
    let top = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    self.transport = transport
    self.target = target
    path = top
    let repository = Repository(url: URL(fileURLWithPath: top, isDirectory: true), runner: GitRunner(transport: transport))
    backend = RemoteBackend(repository: repository)
  }

  func close() {
    transport?.close()
  }

  // MARK: Refresh

  /// Loads status, line counts and branches again; reloads the history's first page when HEAD or a branch moved.
  func refresh() async {
    guard let backend else { return }
    if refreshing {
      refreshAgain = true
      return
    }
    refreshing = true
    defer { refreshing = false }
    repeat {
      refreshAgain = false
      do {
        async let status = backend.status()
        async let branches = backend.branches()
        let (newStatus, newBranches) = try await (status, branches)
        let moved = newBranches.map(\.sha) != self.branches.map(\.sha) || newStatus.headOID != self.status?.headOID
        if newStatus != self.status { self.status = newStatus }
        if newBranches != self.branches { self.branches = newBranches }
        let counts = await backend.lineCounts(newStatus)
        if counts != lineCounts { lineCounts = counts }
        revision += 1
        if moved, !commits.isEmpty { await reloadHistory() }
      } catch {
        if status == nil { report(error, title: "Couldn’t Read the Repository") }
      }
    } while refreshAgain
  }

  /// While the screen is open: one on another machine is looked at again every few seconds.
  func keepFresh() async {
    guard isRemote else { return }
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(8))
      if !Task.isCancelled, !isBusy { await refresh() }
    }
  }

  // MARK: History

  func reloadHistory() async {
    guard let backend else { return }
    isLoadingCommits = true
    defer { isLoadingCommits = false }
    do {
      let page = try await backend.log(skip: 0, limit: Self.pageSize)
      commits = page
      hasMoreCommits = page.count == Self.pageSize
    } catch {
      commits = []
      hasMoreCommits = false
    }
  }

  func loadMoreCommits() async {
    guard let backend, hasMoreCommits, !isLoadingCommits else { return }
    isLoadingCommits = true
    defer { isLoadingCommits = false }
    if let page = try? await backend.log(skip: commits.count, limit: Self.pageSize) {
      commits += page
      hasMoreCommits = page.count == Self.pageSize
    } else {
      hasMoreCommits = false
    }
  }

  // MARK: Actions

  /// Runs an action with its title shown, reports a failure, then refreshes. Whether it succeeded.
  @discardableResult
  func perform(
    _ title: String, failure failureTitle: String, _ action: @escaping (any GitBackend) async throws -> Void
  ) async -> Bool {
    guard let backend, activity == nil else { return false }
    activity = title
    progress = nil
    defer {
      activity = nil
      progress = nil
    }
    do {
      try await action(backend)
      await refresh()
      return true
    } catch {
      report(error, title: failureTitle)
      await refresh()
      return false
    }
  }

  func stage(_ changes: [FileChange]) async {
    await perform("Staging…", failure: "Couldn’t Stage") { try await $0.stage(changes) }
  }

  func unstage(_ changes: [FileChange]) async {
    await perform("Unstaging…", failure: "Couldn’t Unstage") { try await $0.unstage(changes) }
  }

  func stageAll() async {
    await perform("Staging…", failure: "Couldn’t Stage") { try await $0.stageAll() }
  }

  func unstageAll() async {
    await perform("Unstaging…", failure: "Couldn’t Unstage") { try await $0.unstageAll() }
  }

  func discard(_ changes: [FileChange]) async {
    await perform("Discarding…", failure: "Couldn’t Discard") { try await $0.discard(changes) }
  }

  func stageLines(_ lines: Set<Int>, of diff: FileDiff) async {
    await perform("Staging…", failure: "Couldn’t Stage the Lines") { try await $0.stageLines(lines, of: diff) }
  }

  func unstageLines(_ lines: Set<Int>, of diff: FileDiff) async {
    await perform("Unstaging…", failure: "Couldn’t Unstage the Lines") { try await $0.unstageLines(lines, of: diff) }
  }

  func discardLines(_ lines: Set<Int>, of diff: FileDiff) async {
    await perform("Discarding…", failure: "Couldn’t Discard the Lines") { try await $0.discardLines(lines, of: diff) }
  }

  func commit(message: String, amend: Bool = false) async -> Bool {
    await perform("Committing…", failure: "Couldn’t Commit") { _ = try await $0.commit(message: message, amend: amend) }
  }

  func switchTo(_ branch: Branch) async {
    await perform("Switching…", failure: "Couldn’t Switch to \(branch.localName)") { try await $0.switchTo(branch) }
  }

  func createBranch(_ name: String) async -> Bool {
    await perform("Creating \(name)…", failure: "Couldn’t Create \(name)") { try await $0.createBranch(name) }
  }

  /// What Sync does now, the way GitHub Desktop picks: pull what's behind, else push what's ahead (or a branch with
  /// no upstream yet), else fetch.
  enum SyncAction {
    case fetch, pull, push

    var title: String {
      switch self {
      case .fetch: "Fetch"
      case .pull: "Pull"
      case .push: "Push"
      }
    }

    var systemImage: String {
      switch self {
      case .fetch: "arrow.triangle.2.circlepath"
      case .pull: "arrow.down"
      case .push: "arrow.up"
      }
    }
  }

  var syncAction: SyncAction {
    guard let status else { return .fetch }
    if status.behind > 0 { return .pull }
    if status.ahead > 0 || (status.upstream == nil && status.branch != nil && status.headOID != nil) { return .push }
    return .fetch
  }

  func sync(_ action: SyncAction) async {
    let report: @Sendable (String) -> Void = { [weak self] line in
      Task { @MainActor in self?.progress = line }
    }
    switch action {
    case .fetch: await perform("Fetching…", failure: "Couldn’t Fetch") { try await $0.fetch(progress: report) }
    case .pull: await perform("Pulling…", failure: "Couldn’t Pull") { try await $0.pull(progress: report) }
    case .push: await perform("Pushing…", failure: "Couldn’t Push") { try await $0.push(progress: report) }
    }
  }

  func report(_ error: Error, title: String) {
    failure = Failure(title: title, message: Self.describe(error))
  }

  static func describe(_ error: Error) -> String {
    if let error = error as? GitError { return error.message.trimmingCharacters(in: .whitespacesAndNewlines) }
    return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}
