import ComponentKit
import GitKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar: every repository with its state at a glance, then the open repository's
/// Workspace (Changes, History, Stashes), Branches, Remotes and Tags, each a card whose header
/// sums it up, and the bottom bar with the filter and Add.
///
/// Dropping a folder (or picking one with +) adds every git repository inside it, grouped by
/// the folder each is in. Repository states come from a file watcher over the shown ones.
struct SidebarView: View {
  @Environment(RepositoryLibrary.self) private var library
  @Environment(\.modelContext) private var context
  @Query(sort: \SavedRepository.name, order: .forward) private var repositories: [SavedRepository]
  @Binding var selection: String?
  /// Repositories selected together with ⌘- or ⇧-click.
  @State private var selected: Set<String> = []
  @State private var isDropTargeted = false
  @State private var filter = ""

  /// The sidebar's one selection is the open repository's screen; the open repository is the
  /// raised row in Repositories.
  private var mode: Binding<RepositoryMode?> {
    Binding(
      get: { selection.map { library.viewState(for: $0).mode } },
      set: { mode in
        guard let mode, let path = selection else { return }
        let state = library.viewState(for: path)
        withKitAnimation {
          state.mode = mode
          // Changes again leaves the "Merge complete" screen.
          if mode == .changes { state.completedOperation = nil }
        }
      })
  }

  var body: some View {
    @Bindable var library = library
    KitSidebar(selection: mode, searchText: $filter, searchPrompt: "Filter") {
      RepositoryList(selection: $selection, selected: $selected, filter: filter)
      if let selection {
        RepositorySections(
          session: library.session(for: selection), state: library.viewState(for: selection),
          filter: filter)
      }
    } bottomBar: {
      Button("Add Repository", systemImage: "plus") { library.isImporterPresented = true }
        .help("Add the Git repositories in a folder")
    }
    .overlay {
      if repositories.isEmpty {
        EmptyState(
          systemImage: "externaldrive.badge.plus", title: "No Repositories",
          message: "Drop a folder here. Every Git repository inside it is added."
        ) {
          Button("Add Folder…") { library.isImporterPresented = true }.buttonStyle(.kitPrimary)
        }
      }
    }
    .kitDropTarget(isDropTargeted, cornerRadius: KitMetrics.radiusCard)
    .dropDestination(for: URL.self) { urls, _ in
      drop(urls)
      return true
    } isTargeted: { isDropTargeted = $0 }
    .fileImporter(
      isPresented: $library.isImporterPresented, allowedContentTypes: [.folder],
      allowsMultipleSelection: true
    ) { result in
      if case .success(let urls) = result { importFolders(urls) }
    }
    .alert(
      "Nothing to Add",
      isPresented: .init(
        get: { library.importMessage != nil }, set: { if !$0 { library.importMessage = nil } })
    ) {
      Button("OK") {}
    } message: {
      Text(library.importMessage ?? "")
    }
    .alert(
      library.remoteFailure?.title ?? "",
      isPresented: .init(
        get: { library.remoteFailure != nil }, set: { if !$0 { library.remoteFailure = nil } }),
      presenting: library.remoteFailure
    ) { _ in
      Button("OK") {}
    } message: { failure in
      Text(failure.message)
    }
    .task(id: repositories.filter { !$0.isHidden }.map(\.path)) {
      library.groupExistingRepositories(context: context)
      let shown = repositories.filter { !$0.isHidden }.map(\.path)
      library.watchSummaries(of: shown)
      #if DEBUG
        // --add-folder <path> (repeatable) imports folders at launch (or a screenshot scene's), for testing.
        // With --welcome the Welcome window adds them.
        let scene = LaunchScene.shared
        if !scene.folders.isEmpty, repositories.isEmpty, !scene.flag("--welcome") { importFolders(scene.folders) }
      #endif
      await library.refreshSummaries(shown)
    }
  }

  /// A drop outside the list: repositories and groups move to the end, folders are added.
  private func drop(_ urls: [URL]) {
    let result = RepositoryList.sort(urls, known: Set(repositories.map(\.path)))
    for id in result.groups { library.moveGroup(id, before: nil, context: context) }
    if !result.repositories.isEmpty {
      let paths =
        result.repositories.count == 1 && selected.count > 1 && selected.contains(result.repositories[0])
        ? repositories.map(\.path).filter(selected.contains) : result.repositories
      library.move(paths, into: nil, before: nil, context: context)
    }
    if !result.folders.isEmpty { importFolders(result.folders) }
  }

  private func importFolders(_ urls: [URL]) {
    Task {
      let added = await library.importFolders(urls, into: context)
      if let first = added.first { selection = first }
    }
  }
}

// MARK: - The open repository

/// Workspace, Branches, Remotes, Tags and (when there are several) Worktrees.
private struct RepositorySections: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  let filter: String
  @Environment(RepositoryLibrary.self) private var library
  @Environment(\.modelContext) private var context
  @State private var pendingDelete: Branch?
  @State private var branchStart: String?
  @State private var tagTarget: Commit?

  private func matches(_ text: String) -> Bool {
    filter.isEmpty || text.localizedCaseInsensitiveContains(filter)
  }

  var body: some View {
    workspace
    // The checked-out branch first, as in the Branch popover.
    let branches = session.localBranches.filter { matches($0.name) }
      .sorted { $0.isCurrent && !$1.isCurrent }
    if !branches.isEmpty {
      KitSection("Branches", meta: branchesMeta, systemImage: "arrow.triangle.branch", hue: .orange) {
        ForEach(branches) { branch in branchRow(branch) }
      } accessory: {
        Button("New Branch", systemImage: "plus") { branchStart = session.status?.branch ?? "HEAD" }
          .help("Create a branch from \(session.status?.branch ?? "HEAD")")
      }
      .sheet(item: .init(get: { branchStart.map(IdentifiedString.init) }, set: { branchStart = $0?.value })) {
        start in
        NewBranchSheet(session: session, startPoint: start.value == "HEAD" ? nil : start.value)
      }
      .branchDeletion($pendingDelete, session: session)
    }
    let remotes = session.remotes.filter(matches)
    if !remotes.isEmpty {
      KitSection(
        "Remotes", meta: remotesMeta(remotes), systemImage: "cloud", hue: .blue, status: remoteStatus
      ) {
        ForEach(remotes, id: \.self) { remote in
          SidebarRow(remote, systemImage: "cloud") {
            if let date = session.lastFetched { Text("fetched \(date.agoFormatted)") }
          }
          .onRowTap { Task { await session.fetch() } }
          .help("Fetch \(remote)")
        }
      } accessory: {
        Button("Fetch", systemImage: "arrow.clockwise") { Task { await session.fetch() } }
          .disabled(session.isBusy)
          .help("Fetch \(remotes.joined(separator: ", "))")
      }
    }
    let tags = session.tags.filter { matches($0.name) }
    if !tags.isEmpty {
      KitSection("Tags", meta: tagsMeta, systemImage: "tag", hue: .gray) {
        ForEach(tags.prefix(filter.isEmpty ? 12 : 100)) { tag in
          SidebarRow(tag.name, systemImage: "tag")
            .onRowTap {
              state.mode = .history
              state.selectedCommit = tag.commit
            }
            .contextMenu {
              Button("Copy Name") { KitPasteboard.copy(tag.name) }
            }
        }
      } accessory: {
        Button("New Tag", systemImage: "plus") { tagTarget = session.headCommit }
          .disabled(session.headCommit == nil)
          .help("Tag \(session.status?.branch ?? "HEAD")")
      }
      .sheet(item: $tagTarget) { commit in NewTagSheet(session: session, commit: commit) }
    }
    if session.worktrees.count > 1 {
      KitSection("Worktrees", meta: worktreesMeta, systemImage: "folder", hue: .teal) {
        ForEach(session.worktrees) { worktree in
          SidebarRow(worktree.name, systemImage: "folder") {
            Text(worktree.branch ?? "").lineLimit(1).truncationMode(.middle)
          }
          .onRowTap {
            if !worktree.isCurrent { library.open(worktree.url, into: context) }
          }
        }
      }
    }
  }

  // MARK: Workspace

  private var workspace: some View {
    let status = session.status
    let conflicts = status?.conflicted.count ?? 0
    return KitSection(
      Text(session.repository.url.lastPathComponent),
      content: {
        ForEach(RepositoryMode.allCases) { mode in
          SidebarRow(value: mode, mode.title, systemImage: mode.systemImage) {
            switch mode {
            case .changes:
              if conflicts > 0 {
                Count(conflicts, .attention)
              } else if let count = status?.changeCount, count > 0 {
                Count(count, .attention)
              }
            case .stashes:
              if !session.stashes.isEmpty { Count(session.stashes.count) }
            case .history:
              EmptyView()
            }
          }
          .help("\(mode.title) (⌘\(mode.shortcut.character))")
        }
      },
      icon: {
        LiveIcon(systemImage: "arrow.triangle.branch", hue: .blue, status: session.isRefreshing ? .working : .idle)
      },
      meta: { WorkspaceMeta(status: status) },
      accessory: { EmptyView() })
  }

  // MARK: Meta lines

  private var branchesMeta: [String] {
    let local = session.localBranches
    let merged = local.count { !$0.isCurrent && $0.aheadOfHead == 0 && ($0.behindHead ?? 0) > 0 }
    return ["\(local.count) local", merged > 0 ? "\(merged) merged" : ""]
  }

  private func remotesMeta(_ remotes: [String]) -> [String] {
    if let activity = session.activity, Self.remoteActivities.contains(activity) {
      return [session.progress ?? activity.title]
    }
    let fetched = session.lastFetched.map { "fetched \($0.agoFormatted)" } ?? "never fetched"
    return [remotes.count == 1 ? remotes[0] : "\(remotes.count) remotes", fetched]
  }

  private static let remoteActivities: [RepositorySession.Activity] = [.fetching, .pulling, .pushing]

  private var remoteStatus: WorkStatus {
    guard let activity = session.activity, Self.remoteActivities.contains(activity) else { return .idle }
    return .working
  }

  private var tagsMeta: [String] {
    guard let latest = session.tags.first else { return [] }
    return ["Latest \(latest.name)", latest.date?.dayFormatted ?? ""]
  }

  private var worktreesMeta: [String] {
    let detached = session.worktrees.count { $0.branch == nil }
    return ["\(session.worktrees.count) worktrees", detached > 0 ? "\(detached) detached" : ""]
  }

  // MARK: Branches

  private func branchRow(_ branch: Branch) -> some View {
    let isDeleting = session.deletingBranches.contains(branch.id)
    return SidebarRow(branch.name, systemImage: "arrow.triangle.branch") {
      BranchMarks(branch: branch, operation: session.status?.operation, isDeleting: isDeleting)
    }
    .onRowTap {
      if let worktree = session.worktree(for: branch) {
        library.open(worktree.url, into: context)
      } else if !branch.isCurrent {
        Task { await session.switchTo(branch) }
      }
    }
    .disabled(isDeleting)
    .help(branch.isCurrent ? "Checked out" : "Switch to \(branch.name)")
    .contextMenu {
      if !branch.isCurrent {
        Button("Switch to \(branch.name)") { Task { await session.switchTo(branch) } }
          .disabled(session.worktree(for: branch) != nil)
        Button("Merge into \(session.currentBranch?.name ?? "HEAD")") {
          Task { await session.merge(branch) }
        }
        .disabled((branch.aheadOfHead ?? 1) == 0)
      }
      Button("New Branch from \(branch.name)…") { branchStart = branch.name }
      Divider()
      Button("Copy Name") { KitPasteboard.copy(branch.name) }
      if !branch.isCurrent {
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = branch }
          .disabled(session.worktree(for: branch) != nil)
      }
    }
  }
}

/// The Workspace header's status line: the branch, the changed files and the sync.
private struct WorkspaceMeta: View {
  let status: WorkingTreeStatus?

  var body: some View {
    let branch = status?.branch ?? status?.headOID.map { String($0.prefix(7)) } ?? "No commits"
    HStack(spacing: 4) {
      Text(branch)
      if let operation = status?.operation {
        separator
        Text(operation.title).foregroundStyle(Hue.orange.text)
      } else if let count = status?.changeCount, count > 0 {
        separator
        StatusDot(hue: .orange, size: 6)
        Text("\(count) changed")
      }
      if (status?.ahead ?? 0) > 0 || (status?.behind ?? 0) > 0 {
        separator
        SyncCounts(ahead: status?.ahead ?? 0, behind: status?.behind ?? 0)
      }
    }
  }

  private var separator: some View { Text("·").foregroundStyle(.kitTertiary) }
}

/// A branch's state in its row: ↑↓ and a check on the checked-out one, the operation in
/// progress, "merged", or the delete in progress.
private struct BranchMarks: View {
  let branch: Branch
  let operation: RepositoryOperation?
  let isDeleting: Bool

  private var isMerged: Bool {
    !branch.isCurrent && branch.aheadOfHead == 0 && (branch.behindHead ?? 0) > 0
  }

  var body: some View {
    HStack(spacing: 6) {
      if branch.isCurrent, let operation {
        Text(operation.title.lowercased()).fontWeight(.semibold).foregroundStyle(Hue.orange.text)
      } else if isDeleting {
        LiveIcon(systemImage: "trash", hue: .gray, status: .working, size: 14)
        Text("deleting…")
      } else if isMerged {
        Text("merged")
      } else {
        SyncCounts(ahead: branch.ahead, behind: branch.behind)
        if branch.isCurrent {
          Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.kitAccent)
            .accessibilityLabel("Checked out")
            .transition(.scale.combined(with: .opacity))
        }
      }
    }
    .fixedSize()
    .animation(.kit, value: [branch.ahead, branch.behind, branch.isCurrent ? 1 : 0, isDeleting ? 1 : 0])
  }
}

private struct IdentifiedString: Identifiable {
  let value: String
  var id: String { value }
}

extension RepositoryMode {
  var shortcut: KeyEquivalent {
    switch self {
    case .changes: "1"
    case .history: "2"
    case .stashes: "3"
    }
  }
}

extension View {
  /// Runs `action` when the row is clicked (or activated with VoiceOver), for sidebar rows that
  /// do something instead of being selected.
  func onRowTap(_ action: @escaping () -> Void) -> some View {
    simultaneousGesture(TapGesture().onEnded(action))
      .accessibilityAction { action() }
  }
}

/// A repository's state at a glance: the operation in progress, an orange dot with the number of
/// changed files, ↑ commits to push and ↓ commits to pull. Nothing when it is up to date.
struct StatusMarks: View {
  let summary: RepositorySummary

  var body: some View {
    HStack(spacing: 6) {
      if let operation = summary.operation {
        Chip(operation.title, hue: .orange).controlSize(.small)
      }
      SyncCounts(changes: summary.changeCount, ahead: summary.ahead, behind: summary.behind)
    }
    .animation(.kit, value: summary)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.description(summary))
  }

  static func description(_ summary: RepositorySummary) -> String {
    func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }
    var parts: [String] = []
    if let operation = summary.operation {
      parts.append(
        summary.conflictCount > 0
          ? "\(operation.title), \(count(summary.conflictCount, "conflict"))" : operation.title)
    }
    if summary.changeCount > 0 { parts.append(count(summary.changeCount, "uncommitted change")) }
    if summary.ahead > 0 { parts.append(count(summary.ahead, "commit") + " to push") }
    if summary.behind > 0 { parts.append(count(summary.behind, "commit") + " to pull") }
    return parts.isEmpty ? "Up to date" : parts.joined(separator: ", ")
  }
}
