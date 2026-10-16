import AppKit
import GitKit
import SwiftData
import SwiftUI

/// What the window shows for a repository: the Workspace items in the sidebar.
enum RepositoryMode: String, CaseIterable, Identifiable {
  case changes, history, stashes
  var id: Self { self }
  var title: String {
    switch self {
    case .changes: "Changes"
    case .history: "History"
    case .stashes: "Stashes"
    }
  }
  var systemImage: String {
    switch self {
    case .changes: "pencil"
    case .history: "clock"
    case .stashes: "archivebox"
    }
  }
}

/// A merge, rebase, cherry-pick or revert that just finished, for the completion screen.
struct CompletedOperation: Equatable {
  var operation: RepositoryOperation
  var source: String?
  var branch: String?
}

/// Per-repository UI state that survives switching repositories: selections, the commit
/// message draft and conflict choices that aren't written yet.
@Observable final class RepositoryViewState {
  var mode: RepositoryMode = .changes
  var selectedChanges: Set<FileChange.ID> = []
  /// The commit shown in the inspector, where ↑/↓ move from.
  var selectedCommit: Commit.ID?
  /// Every selected commit, `selectedCommit` included; ⇧ selects several.
  var selectedCommits: Set<Commit.ID> = []
  var selectedCommitFile: CommitFile.ID?
  var summary = ""
  var details = ""
  var amend = false
  /// The Publish sheet, for a repository without a remote.
  var isPublishPresented = false

  // Conflicts: choices are kept here and written when the operation continues.
  /// Every path that was conflicted during the current operation, in order.
  var conflictPaths: [String] = []
  /// The number of conflict blocks each path had, for progress after it is resolved.
  var conflictBlockCounts: [String: Int] = [:]
  var conflictChoices: [String: [Int: ConflictResolution]] = [:]
  var wholeFileChoices: [String: ConflictSide] = [:]
  var selectedConflict: String?
  var completedOperation: CompletedOperation?

  func resetConflicts() {
    conflictPaths = []
    conflictBlockCounts = [:]
    conflictChoices = [:]
    wholeFileChoices = [:]
    selectedConflict = nil
  }
}

/// The app's repositories: one session and view state per repository, sidebar summaries, and
/// recursive folder import.
@MainActor @Observable final class RepositoryLibrary {
  private(set) var sessions: [String: RepositorySession] = [:]
  private(set) var viewStates: [String: RepositoryViewState] = [:]
  private(set) var summaries: [String: RepositorySummary] = [:]
  private(set) var isImporting = false
  var isImporterPresented = false
  var isClonePresented = false
  /// Asks the window to run New Repository (it needs the window's model context).
  var isCreateRequested = false
  /// A repository to select in the window (set by `open`).
  var requestedSelection: String?
  /// Shown after an import that found nothing.
  var importMessage: String?
  /// Repositories with a fetch, pull or push started from the sidebar.
  var remoteActivity: [String: RemoteAction] = [:]
  /// The repositories a sidebar fetch, pull or push failed in.
  var remoteFailure: RemoteFailure?

  /// Shares the repository list with the other v57 apps through the vault.
  @ObservationIgnored let vaultProjects = VaultProjects()

  private weak var activeSession: RepositorySession?
  /// The repository on screen.
  var openSession: RepositorySession? { activeSession }
  private var summaryWatcher: RepositoryWatcher?
  private var watchedPaths: [String] = []
  private var pendingSummaries: [String: Task<Void, Never>] = [:]

  func session(for path: String) -> RepositorySession {
    if let session = sessions[path] { return session }
    let session = RepositorySession(url: URL(fileURLWithPath: path, isDirectory: true))
    sessions[path] = session
    return session
  }

  func viewState(for path: String) -> RepositoryViewState {
    if let state = viewStates[path] { return state }
    let state = RepositoryViewState()
    viewStates[path] = state
    return state
  }

  /// Watches only the repository on screen, and remembers when it was opened for the Welcome
  /// window's Recent list.
  func activate(_ path: String?, context: ModelContext? = nil) async {
    if let path, let context {
      let saved = try? context.fetch(
        FetchDescriptor<SavedRepository>(predicate: #Predicate { $0.path == path }))
      saved?.first?.lastOpenedAt = .now
      try? context.save()
    }
    // The remote may have changed since the repository was published.
    if let path, let context,
      let saved = try? context.fetch(FetchDescriptor<SavedRepository>(predicate: #Predicate { $0.path == path })).first
    {
      Task { await vaultProjects.publish([saved], context: context) }
    }
    let session = path.map(session(for:))
    if activeSession !== session {
      activeSession?.deactivate()
      activeSession = session
    }
    await session?.activate()
    if let session, let path { updateSummary(path, from: session) }
  }

  func updateSummary(_ path: String, from session: RepositorySession) {
    guard let status = session.status else { return }
    summaries[path] = RepositorySummary(status)
  }

  /// Keeps every repository's sidebar summary current without opening it: one FSEvents stream
  /// over all of them refreshes a repository's summary shortly after its files or refs change.
  func watchSummaries(of paths: [String]) {
    guard paths != watchedPaths else { return }
    watchedPaths = paths
    summaryWatcher?.stop()
    summaryWatcher = nil
    guard !paths.isEmpty else { return }
    let roots = paths
    let watcher = RepositoryWatcher(
      paths: paths.map { URL(fileURLWithPath: $0, isDirectory: true) }, latency: 1
    ) { [weak self] changed in
      // The innermost repository containing each path, for repositories nested in others.
      let touched = Set(
        changed.compactMap { path in
          roots.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        })
      Task { @MainActor in self?.scheduleSummaryRefresh(touched) }
    }
    watcher.start()
    summaryWatcher = watcher
  }

  /// Reloads every watched repository's summary, e.g. when the app becomes active.
  func refreshAllSummaries() async {
    await refreshSummaries(watchedPaths)
  }

  private func scheduleSummaryRefresh(_ paths: Set<String>) {
    for path in paths {
      // The open repository keeps its own summary current.
      if activeSession?.repository.url.path == path { continue }
      pendingSummaries[path]?.cancel()
      pendingSummaries[path] = Task {
        // Let a burst of writes (a build, a checkout) settle first.
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        pendingSummaries[path] = nil
        await refreshSummaries([path])
      }
    }
  }

  /// Reloads branch and change counts for the sidebar, a few repositories at a time.
  func refreshSummaries(_ paths: [String]) async {
    await withTaskGroup(of: (String, RepositorySummary?).self) { group in
      var pending = paths[...]
      func addNext() {
        guard let path = pending.popFirst() else { return }
        group.addTask {
          let summary = try? await Repository(url: URL(fileURLWithPath: path)).summary()
          return (path, summary)
        }
      }
      for _ in 0..<6 { addNext() }
      for await (path, summary) in group {
        if let summary { summaries[path] = summary } else { summaries[path] = nil }
        addNext()
      }
    }
  }

  /// Adds every repository found in the dropped or picked folders. Returns the added paths.
  @discardableResult
  func importFolders(_ urls: [URL], into context: ModelContext) async -> [String] {
    let folders = urls.filter {
      $0.isFileURL && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    guard !folders.isEmpty else { return [] }
    isImporting = true
    defer { isImporting = false }

    let found = await RepoDiscovery.scan(folders)
    let all = (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []
    let existing = Dictionary(all.map { ($0.path, $0) }) { first, _ in first }
    var added: [SavedRepository] = []
    // Found repositories that are already in the list but in no group are grouped again.
    var regrouped: [SavedRepository] = []
    for folder in folders {
      let repos = found[folder] ?? []
      for repo in repos {
        if let saved = existing[repo.path] {
          if saved.groupID == nil, !regrouped.contains(saved) { regrouped.append(saved) }
        } else if !added.contains(where: { $0.path == repo.path }) {
          let saved = SavedRepository(path: repo.path, group: folder.standardizedFileURL.path)
          context.insert(saved)
          added.append(saved)
        }
      }
    }
    arrange(added + regrouped, new: Set(added.map(\.path)), context: context)
    try? context.save()
    await vaultProjects.publish(added, context: context)

    let foundCount = found.values.reduce(0) { $0 + $1.count }
    if foundCount == 0 {
      let names = folders.map(\.lastPathComponent).formatted()
      importMessage = "No Git repositories were found in \(names)."
    }
    await refreshSummaries(added.map(\.path))
    return added.map(\.path)
  }

  /// Shows `url` (a repository or worktree), adding it to the sidebar first if needed.
  func open(_ url: URL, into context: ModelContext) {
    let path = url.standardizedFileURL.path
    let existing = (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []
    if existing.contains(where: { $0.path == path }) {
      requestedSelection = path
      return
    }
    let saved = SavedRepository(path: path, group: url.deletingLastPathComponent().path)
    context.insert(saved)
    // A worktree inside a repository in the list joins that repository's group.
    if let owner = existing.first(where: { path.hasPrefix($0.path + "/") }), let groupID = owner.groupID {
      saved.groupID = groupID
      saved.sortIndex = existing.filter { $0.groupID == groupID }.count
    } else {
      arrange([saved], new: [path], context: context)
    }
    try? context.save()
    requestedSelection = path
    Task {
      await vaultProjects.publish([saved], context: context)
      await refreshSummaries([path])
    }
  }

  /// Adds repositories another app put in the vault, without selecting them.
  func adopt(_ paths: [String], into context: ModelContext) {
    let added = paths.map { path in
      let saved = SavedRepository(path: path, group: (path as NSString).deletingLastPathComponent)
      context.insert(saved)
      return saved
    }
    arrange(added, new: Set(paths), context: context)
    try? context.save()
    Task { await refreshSummaries(paths) }
  }

  /// Asks where to create a repository, runs `git init` there and adds it.
  func createRepository(into context: ModelContext) async {
    let panel = NSSavePanel()
    panel.title = "New Repository"
    panel.prompt = "Create"
    panel.nameFieldLabel = "Name:"
    panel.nameFieldStringValue = "New Repository"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let repository = try await Repository.initialize(at: url)
      open(repository.url, into: context)
    } catch {
      importMessage = (error as? GitError)?.message ?? error.localizedDescription
    }
  }

  func remove(_ repositories: [SavedRepository], from context: ModelContext) {
    vaultProjects.unpublish(repositories.map(\.path))
    for repository in repositories {
      sessions[repository.path]?.deactivate()
      sessions[repository.path] = nil
      viewStates[repository.path] = nil
      summaries[repository.path] = nil
      context.delete(repository)
    }
    try? context.save()
    deleteEmptyGroups(Set(repositories.compactMap(\.groupID)), context: context)
    try? context.save()
  }

  // MARK: Finder and Terminal

  static func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  static func openInTerminal(_ url: URL) {
    guard
      let terminal = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.Terminal")
    else { return }
    NSWorkspace.shared.open(
      [url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
  }
}
