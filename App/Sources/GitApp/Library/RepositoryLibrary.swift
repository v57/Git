import ComponentKit
import GitHubKit
import GitKit
import GitRemote
import GitUI
import SwiftData
import SwiftUI
import VaultKit
import VaultUI

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
  /// The toolbar's Branch popover.
  var isBranchPopoverPresented = false

  // Conflicts: choices are kept here and written when the operation continues.
  /// Every path that was conflicted during the current operation, in order.
  var conflictPaths: [String] = []
  /// The number of conflict blocks each path had, for progress after it is resolved.
  var conflictBlockCounts: [String: Int] = [:]
  var conflictChoices: [String: [Int: ConflictResolution]] = [:]
  var wholeFileChoices: [String: GitKit.ConflictSide] = [:]
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

/// A window's repositories: one session and view state per repository, sidebar summaries, and
/// recursive folder import. Each window has its own, on the vault account it shows (`GitWindow`).
@MainActor @Observable final class RepositoryLibrary {
  private(set) var sessions: [String: RepositorySession] = [:]
  private(set) var viewStates: [String: RepositoryViewState] = [:]
  private(set) var summaries: [String: RepositorySummary] = [:]
  /// When each repository was last committed to, pushed and changed, for the sidebar's sorting and filtering and
  /// the All Repositories page.
  private(set) var activities: [String: RepositoryActivity] = [:]
  /// The All Repositories page is up instead of a repository's screen.
  var showsAllRepositories = false
  private(set) var isImporting = false
  var isImporterPresented = false
  var isClonePresented = false
  /// Asks the window to run New Repository (it needs the window's model context).
  var isCreateRequested = false
  /// A repository to select in the window (set by `open`).
  var requestedSelection: String?
  /// What the import under way found that Git doesn't list (folders without a repository, databases), offered to
  /// the other apps before anything is added; `offerClosed()` goes on with what was ticked.
  var importOffer: VaultImportOffer?
  /// What the offer's Add ticked, taken when it closes (none after Not Now).
  var offerPicks: [URL] = []
  private var offerDecision: CheckedContinuation<[URL], Never>?
  /// Shown after an import that found nothing.
  var importMessage: String?
  /// Repositories with a fetch, pull or push started from the sidebar.
  var remoteActivity: [String: RemoteAction] = [:]
  /// How each repository's last sidebar fetch, pull or push ended, for its row's effect.
  var remoteOutcomes: [String: RemoteOutcome] = [:]
  /// The repositories a sidebar fetch, pull or push failed in.
  var remoteFailure: RemoteFailure?

  /// Asks for the account's name and email at the first commit that needs them (the window shows its sheet).
  @ObservationIgnored let profileRequest = VaultProfileRequest()

  /// Shares the repository list and its groups with the other v57 apps through the vault.
  @ObservationIgnored let vaultProjects: VaultProjects
  /// The store the sidebar's groups live in (`VaultProjectTree`): the window's account.
  var vault: Vault { vaultProjects.vault }

  init(vault: Vault) {
    vaultProjects = VaultProjects(vault: vault)
    // The last launch's values, until the first refresh looks again: most are the same.
    if let lastState {
      summaries = lastState.contents.summaries
      activities = lastState.contents.activities
    }
  }

  /// What Git showed when it last ran (`LastState`); nil for `--in-memory` launches, which leave it alone.
  private var lastState: LastState? {
    vaultProjects.isShared || LastState.debugFile != nil ? LastState.shared : nil
  }

  /// Saves the sidebar's values and the loaded repositories' changes for the next launch.
  private func rememberState() {
    lastState?.remember(summaries: summaries, activities: activities, sessions: sessions)
  }

  /// Repositories of another account that `open` showed in this window, by path, with their account (nil for
  /// Personal).
  private var otherAccounts: [String: String?] = [:]

  /// How git runs in a repository: with the GitHub sign-in of the account it belongs to (`SavedRepository.accountID`,
  /// `GitCredentials`' account, nil for Personal), which is the window's for every repository it lists.
  func runner(for path: String) -> GitRunner {
    GitRunner(credentialAccount: otherAccounts[path] ?? (vault.isPersonal ? nil : vault.accountID))
  }

  /// Whether a repository is in this window's account (`SavedRepository.accountID`).
  func owns(_ repository: SavedRepository) -> Bool { vaultProjects.owns(repository) }

  /// Saves a repository in the window's account.
  private func insert(path: String, group: String, into context: ModelContext) -> SavedRepository {
    let saved = SavedRepository(path: path, group: group)
    if !vault.isPersonal { saved.accountID = vault.accountID }
    context.insert(saved)
    return saved
  }

  /// The groups collapsed in this app's sidebar (vault group ids); each app keeps its own.
  var collapsedGroups: Set<String> = RepositoryLibrary.savedCollapsedGroups {
    didSet { if vaultProjects.isShared { UserDefaults.standard.set(Array(collapsedGroups), forKey: Self.collapsedKey) } }
  }
  private static let collapsedKey = "CollapsedGroups"
  private static var savedCollapsedGroups: Set<String> {
    Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
  }

  private weak var activeSession: RepositorySession?
  /// The repository on screen.
  var openSession: RepositorySession? { activeSession }
  private var summaryWatcher: RepositoryWatcher?
  private var watchedPaths: [String] = []
  private var pendingSummaries: [String: Task<Void, Never>] = [:]

  /// The session of a repository on this Mac (`path`); see `loadedSession(for:)` for one that may be on another
  /// device.
  func session(for path: String) -> RepositorySession {
    if let session = sessions[path] { return session }
    let session = RepositorySession(
      repository: Repository(url: URL(fileURLWithPath: path, isDirectory: true), runner: runner(for: path)))
    identify(session, accountID: otherAccounts[path].flatMap { $0 } ?? vault.accountID)
    // Its changes as the last launch left them, shown while its first refresh looks again.
    if let snapshot = lastState?.contents.sessions[path] { session.restore(snapshot) }
    sessions[path] = session
    return session
  }

  /// The session of the repository `key` selects: one here (a path) always has one; one on another device (a
  /// `remoteKey`) once it is connected (`connect`).
  func loadedSession(for key: String) -> RepositorySession? {
    Self.isRemote(key) ? sessions[key] : session(for: key)
  }

  /// Who commits in the session's repository: asked at the first commit that needs it.
  private func identify(_ session: RepositorySession, accountID: String) {
    session.identity = { [weak self, weak session] activity in
      guard let self, let session else { return [:] }
      return await self.commitEnvironment(for: activity, in: session.repository, accountID: accountID)
    }
  }

  // MARK: On your devices

  /// What a repository on another device is selected by: the window's selection is a path for one on this Mac.
  static func remoteKey(_ repository: RemoteRepository) -> String { remotePrefix + repository.id }
  static func isRemote(_ key: String) -> Bool { key.hasPrefix(remotePrefix) }
  private static let remotePrefix = "remote:"

  /// The repositories on the user's other devices that aren't on this Mac: the vault's projects with a folder on a
  /// device Git can sign in to (a Hub's, or a Mac that let this one in through Settings ▸ Remote).
  var remoteRepositories: [RemoteRepository] { RemoteRepositories.all(vault: vault) }

  func remoteRepository(_ key: String) -> RemoteRepository? {
    remoteRepositories.first { Self.remoteKey($0) == key }
  }

  /// A repository on another device at a glance: its session's summary once it's open, else how its device last saw
  /// it (the vault's status, which that device keeps current), else how it was when this Mac last had it open.
  func remoteSummary(_ repository: RemoteRepository) -> RepositorySummary? {
    let key = Self.remoteKey(repository)
    if sessions[key] != nil, let summary = summaries[key] { return summary }
    return repository.lastSeen?.status.summary ?? summaries[key]
  }

  /// A repository on another device while it connects, or why it couldn't; nil once it has a session.
  enum RemoteState: Equatable {
    case connecting(String)
    case failed(String)
  }
  private(set) var remoteStates: [String: RemoteState] = [:]
  /// The device each connected repository on another device is on.
  private(set) var remoteTargets: [String: RemoteTarget] = [:]
  @ObservationIgnored private var remoteTransports: [String: SSHGitTransport] = [:]

  /// Signs in to the first of the repository's devices that answers and makes its session, whose git runs there
  /// (`SSHGitTransport`). Nothing when it has one or is connecting.
  func connect(_ key: String) async {
    guard sessions[key] == nil else { return }
    if case .connecting = remoteStates[key] { return }
    guard let repository = remoteRepository(key) else {
      remoteStates[key] = .failed("The repository isn’t on any of your devices any more.")
      return
    }
    remoteStates[key] = .connecting("Connecting to \(repository.targets.first?.name ?? "the device")…")
    do {
      let opened = try await RemoteRepositories.open(repository, vault: vault) { [weak self] target in
        self?.remoteStates[key] = .connecting("Connecting to \(target.name)…")
      }
      let session = RepositorySession(repository: opened.repository)
      identify(session, accountID: vault.accountID)
      // Its changes as this Mac last saw them, else as the device itself last did (the vault's status), shown
      // while the first refresh reads them.
      if let snapshot = lastState?.contents.sessions[key] ?? repository.lastSeen?.status.snapshot {
        session.restore(snapshot)
      }
      remoteTransports[key] = opened.transport
      remoteTargets[key] = opened.target
      sessions[key] = session
      remoteStates[key] = nil
    } catch {
      remoteStates[key] = .failed(RemoteRepositories.describe(error))
    }
  }

  /// Tries a repository on another device again after it failed.
  func reconnect(_ key: String) async {
    remoteStates[key] = nil
    await connect(key)
  }

  /// What the repository's summary is kept under: its path here, or its key for one on another device (whose path
  /// there may be the path of another repository here).
  func key(of session: RepositorySession) -> String {
    guard session.repository.isRemote else { return session.repository.url.path }
    return sessions.first { $0.value === session }?.key ?? session.repository.url.path
  }

  /// Who commits in a repository of `accountID` (`CommitIdentity`): asks once, at the first commit that needs it,
  /// and then whether git in Terminal should use the name too (`TerminalIdentity`).
  private func commitEnvironment(
    for activity: RepositorySession.Activity, in repository: Repository, accountID: String
  ) async -> [String: String]? {
    let vaults = Vaults.shared
    let account = vaults.account(id: accountID) ?? .personal
    let configured = await repository.identityConfiguration()
    let offer = TerminalIdentity.shouldOffer(account: account, configured: configured)
    var terminal: Bool?  // the Your Name sheet's switch, when it showed
    let answer = await CommitIdentity.answer(for: activity, configured: configured, profile: vaults.profile(for: account)) {
      let answer = await profileRequest.answer(
        for: account, vaults: vaults, reason: CommitIdentity.reason,
        gitHub: (GitHubAccount.forAccount(accountID).user?.name, nil), option: offer ? TerminalIdentity.option : nil)
      terminal = answer?.option
      return answer?.profile
    }
    guard let answer else { return nil }
    if offer, let profile = answer.profile, terminal != nil || activity.alwaysCommits {
      if terminal == nil {
        terminal = await profileRequest.answer(for: account, vaults: vaults, option: TerminalIdentity.option)?.option
      }
      if let terminal { await TerminalIdentity.answered(terminal, profile: profile) }
    }
    return answer.profile?.gitEnvironment ?? [:]
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
    if let path, Self.isRemote(path) {
      await connect(path)
      // Another repository was picked while it connected.
      if Task.isCancelled { return }
    }
    let session = path.flatMap(loadedSession(for:))
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
    rememberState()
    // The dates are read here, from git on this Mac.
    guard !Self.isRemote(path) else { return }
    Task { await refreshActivity(path) }
    keepStatus(status, at: path)
  }

  /// Keeps how a repository here is in its vault project, for the user's other devices (`VaultProject.Status`:
  /// branch, counts and files, written only when they changed; nothing for one that isn't a project of the window's
  /// account).
  private func keepStatus(_ status: WorkingTreeStatus, at path: String) {
    vault.setStatus(VaultProject.Status(status), ofProjectAt: path)
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
    await withTaskGroup(of: (String, WorkingTreeStatus?, RepositoryActivity?).self) { group in
      var pending = paths[...]
      func addNext() {
        guard let path = pending.popFirst() else { return }
        group.addTask {
          let repository = Repository(url: URL(fileURLWithPath: path))
          async let status = try? repository.summaryStatus()
          async let activity = try? repository.activity()
          return (path, await status, await activity)
        }
      }
      for _ in 0..<6 { addNext() }
      for await (path, status, activity) in group {
        let summary = status.map(RepositorySummary.init)
        if let summary { summaries[path] = summary } else { summaries[path] = nil }
        if activities[path] != activity { activities[path] = activity }
        // The open repository's session keeps its own (its files list an untracked folder's files, these don't).
        if let status, !(activeSession.map { !$0.repository.isRemote && $0.repository.url.path == path } ?? false) {
          keepStatus(status, at: path)
        }
        addNext()
      }
    }
    rememberState()
  }

  /// Reloads one repository's dates (the open one, whose summary comes from its session).
  func refreshActivity(_ path: String) async {
    let activity = try? await Repository(url: URL(fileURLWithPath: path)).activity()
    if activities[path] != activity {
      activities[path] = activity
      rememberState()
    }
  }

  /// Adds every repository found in the dropped or picked folders, the new items (repositories, groups for folders
  /// of several) into `group` (a vault group id; `nil`: the top level) before the sidebar item `before` (`nil`: in
  /// name order at the end). Returns the added paths.
  ///
  /// Nothing changes until it all can at once: the folders are scanned and the repositories' remotes read first,
  /// then the offer of what Git doesn't list is asked (when there is any), then the repositories, the folders ticked
  /// there and the groups they make are saved in one go, so the list updates once.
  @discardableResult
  func importFolders(
    _ urls: [URL], into context: ModelContext, group: String? = nil, before: String? = nil
  ) async -> [String] {
    let files = urls.filter(\.isFileURL)
    let folders = files.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    guard !files.isEmpty else { return [] }
    isImporting = true
    defer { isImporting = false }

    // Files too: a database dropped here is offered as a connection.
    let results = await VaultProjectDiscovery.scan(files)
    let found = Dictionary(results.map { ($0.root, $0.repositories) }) { first, _ in first }
    let all = (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []
    let existing = Dictionary(all.map { ($0.path, $0) }) { first, _ in first }
    var new: [(path: String, folder: String)] = []
    // Found repositories that are already in the list but in no group are grouped again.
    var regrouped: [String] = []
    for folder in folders {
      for repo in found[folder.standardizedFileURL] ?? [] {
        if let saved = existing[repo.path] {
          // One in another account's list stays there.
          if owns(saved), !regrouped.contains(repo.path) { regrouped.append(repo.path) }
        } else if !new.contains(where: { $0.path == repo.path }) {
          new.append((repo.path, folder.standardizedFileURL.path))
        }
      }
    }
    let remotes = await Self.remotes(of: new.map(\.path))
    let beforeID = before.flatMap(layout(context).vaultID(of:))

    // Folders without a repository and databases, for the other apps: asked before anything is added. The
    // repositories Git takes itself (or another account's list has).
    let others = results.map { result in
      var result = result
      result.repositories = []
      return result
    }
    var picked: [URL] = []
    var databases: [VaultProjectDiscovery.DatabaseFile] = []
    if let offer = VaultImportOffer(others, store: vault.store) {
      isImporting = false
      picked = await withCheckedContinuation { decision in
        offerDecision = decision
        offerPicks = []
        importOffer = offer
      }
      isImporting = true
      databases = offer.databases.filter { picked.contains($0.url) }
    } else if results.allSatisfy(\.repositories.isEmpty) {
      let names = folders.map(\.lastPathComponent).formatted()
      importMessage = "No Git repositories were found in \(names)."
    }
    let folderPaths = picked.filter { url in !databases.contains { $0.url == url } }.map(\.standardizedFileURL.path)

    // All at once: the vault's projects and groups, then the list's rows.
    let paths = new.map(\.path)
    vault.perform { store in
      for path in paths { try store.addProject(path: path, remoteURL: remotes[path]) }
      for path in folderPaths { try store.addProject(path: path) }
      try store.arrangeProjects(
        paths + regrouped + folderPaths, roots: results.map(\.root.path), into: group, before: beforeID)
      for database in databases { try store.addDatabaseFile(database) }
    }
    for item in new { _ = insert(path: item.path, group: item.folder, into: context) }
    try? context.save()
    await refreshSummaries(paths)
    return paths
  }

  /// The import's offer closed: it goes on with what Add ticked (nothing after Not Now).
  func offerClosed() {
    let decision = offerDecision
    offerDecision = nil
    decision?.resume(returning: offerPicks)
    offerPicks = []
  }

  /// Each repository's `origin`, read side by side.
  private static func remotes(of paths: [String]) async -> [String: String] {
    await withTaskGroup(of: (String, String?).self) { group in
      for path in paths {
        group.addTask {
          let remote = try? await Repository(url: URL(fileURLWithPath: path, isDirectory: true)).remoteURL("origin")
          return (path, remote?.isEmpty == false ? remote : nil)
        }
      }
      var remotes: [String: String] = [:]
      for await (path, remote) in group { remotes[path] = remote }
      return remotes
    }
  }

  /// Shows `url` (a repository or worktree), adding it to the sidebar first if needed.
  func open(_ url: URL, into context: ModelContext) {
    let path = url.standardizedFileURL.path
    let existing = (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []
    if let saved = existing.first(where: { $0.path == path }) {
      if !owns(saved) {
        // Pushes there use its own account's sign-in, loaded now so git has the token.
        otherAccounts[path] = saved.accountID
        _ = GitHubAccount.forAccount(saved.accountID ?? VaultAccount.personal.id)
      }
      requestedSelection = path
      return
    }
    let saved = insert(path: path, group: url.deletingLastPathComponent().path, into: context)
    try? context.save()
    requestedSelection = path
    // A worktree inside a repository in the list joins that repository's group.
    let owner = existing.first { owns($0) && path.hasPrefix($0.path + "/") }.flatMap { layout(context).groupID(of: $0.path) }
    Task {
      await vaultProjects.publish([saved], context: context)
      if let owner {
        move([path], into: owner, before: nil, context: context)
      } else {
        arrange([path])
      }
      await refreshSummaries([path])
    }
  }

  /// Adds repositories another app put in the vault, without selecting them.
  func adopt(_ paths: [String], into context: ModelContext) {
    for path in paths {
      _ = insert(path: path, group: (path as NSString).deletingLastPathComponent, into: context)
    }
    try? context.save()
    // Projects another app or Mac already put in a group stay there.
    arrange(paths)
    Task { await refreshSummaries(paths) }
  }

  /// Asks where to create a repository, runs `git init` there and adds it.
  func createRepository(into context: ModelContext) async {
    guard let url = await KitDesktop.chooseSaveLocation(title: "New Repository", prompt: "Create", name: "New Repository")
    else { return }
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
      activities[repository.path] = nil
      context.delete(repository)
    }
    lastState?.forget(repositories.map(\.path))
    try? context.save()
  }

  /// The vault's projects on this Mac that aren't in the list: folders without a repository (notes, a website's
  /// research) another app or an import added, and checkouts of another account's list.
  func unlistedProjects(besides repositories: [SavedRepository]) -> [VaultProject] {
    let listed = Set(repositories.map(\.path))
    let vault = vaultProjects.vault
    return vault.localProjects.filter { project in project.paths[vault.deviceID].map { !listed.contains($0) } ?? false }
  }

  /// Removes the repositories from the list and every project on this Mac from the vault, the unlisted ones too, so
  /// no v57 app lists them here any more (a project another device has stays there). Their folders stay on disk.
  func removeAllProjects(_ repositories: [SavedRepository], from context: ModelContext) {
    let vault = vaultProjects.vault
    let unlisted = unlistedProjects(besides: repositories).compactMap { $0.paths[vault.deviceID] }
    remove(repositories, from: context)
    vaultProjects.unpublish(unlisted)
  }

  // MARK: Finder and Terminal

  static func reveal(_ url: URL) {
    KitDesktop.reveal([url])
  }

  static func openInTerminal(_ url: URL) {
    KitDesktop.openTerminal(at: url)
  }
}
