import ComponentKit
import GitHubKit
import GitKit
import SwiftData
import SwiftUI

/// The main window: the sidebar and the open repository's screen.
struct ContentView: View {
  @Environment(RepositoryLibrary.self) private var library
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.modelContext) private var context
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  @SceneStorage("selectedRepository") private var selectedPath: String?
  @State private var columns = NavigationSplitViewVisibility.all
  /// The repository on screen: the selection once its first status has loaded (`showSelection`).
  @State private var shownPath: String?

  /// The repository whose screen is up; at launch, before one is shown, the selection itself.
  private var screenPath: String? { selectedPath == nil ? nil : shownPath ?? selectedPath }

  var body: some View {
    @Bindable var library = library
    NavigationSplitView(columnVisibility: $columns) {
      // The sidebar has its own hide button; the kit's toolbar brings a hidden sidebar back.
      SidebarView(selection: $selectedPath, columns: $columns)
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
    } detail: {
      Group {
        if let path = screenPath {
          // Another repository swaps in at once: every screen has the same panes and toolbar, so a fade would
          // redraw the whole pane for what is only new content.
          RepositoryScreen(session: library.session(for: path), state: library.viewState(for: path))
            .id(path)
        } else {
          EmptyState(
            systemImage: "folder", title: "No Repository Selected", message: "Choose a repository in the sidebar."
          ) {
            Button("Show Welcome Window") { openWindow(id: WelcomeWindow.id) }.buttonStyle(.kit)
          }
          .kitPane(.content)
          .kitToolbar("Git") { EmptyView() } tools: {}
        }
      }
      .kitSidebarToggle(columnVisibility: $columns)
    }
    .frame(minWidth: 1100, minHeight: 600)
    .onChange(of: library.requestedSelection, initial: true) { _, path in
      guard let path else { return }
      selectedPath = path
      library.requestedSelection = nil
    }
    .focusedSceneValue(\.repositorySession, screenPath.map(library.session(for:)))
    .focusedSceneValue(\.repositoryViewState, screenPath.map(library.viewState(for:)))
    .sheet(isPresented: $library.isClonePresented) { CloneSheet() }
    .onChange(of: library.isCreateRequested) { _, requested in
      guard requested else { return }
      library.isCreateRequested = false
      Task { await library.createRepository(into: context) }
    }
    .task { library.vaultProjects.start(context: context, library: library) }
    // A folder opened in Git (Shell's Open With, `open -a Git <folder>`): added if needed, then shown.
    .onOpenURL { url in
      guard url.isFileURL else { return }
      library.open(url, into: context)
    }
    .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    .task(id: selectedPath) { await showSelection() }
    .task(id: selectedPath) {
      await library.activate(selectedPath, context: context)
      #if DEBUG
        // A screenshot scene's repository: its screen from the arguments, then the picture.
        let scene = LaunchScene.shared
        if let path = selectedPath, scene.includes(path) {
          await applyLaunchArguments(library.viewState(for: path), session: library.session(for: path))
          scene.loaded(welcome: false)
        }
      #endif
    }
    #if DEBUG
      .task { LaunchScene.shared.prepare(library: library, context: context) }
      // The next screenshot scene: its repositories are added again (SidebarView), and it may want the Welcome
      // window instead.
      .onChange(of: LaunchScene.shared.generation) {
        selectedPath = nil
        if LaunchScene.shared.flag("--welcome") {
          openWindow(id: WelcomeWindow.id)
        } else {
          dismissWindow(id: WelcomeWindow.id)
        }
      }
    #endif
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task {
        if let path = selectedPath { await library.session(for: path).refresh() }
        await library.refreshAllSummaries()
      }
    }
  }

  /// Shows the selected repository. One opened for the first time keeps the previous screen up until its status,
  /// branches and remotes are in (a short while at most), so it doesn't show a loading screen and then fill in.
  private func showSelection() async {
    guard let path = selectedPath else {
      shownPath = nil
      return
    }
    let session = library.session(for: path)
    if shownPath != nil {
      // `activate` (the other task) loads it; the first load ends with the first revision.
      let deadline = ContinuousClock.now + .milliseconds(400)
      while session.revision == 0, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
      }
      guard !Task.isCancelled else { return }
    }
    shownPath = path
  }
}

#if DEBUG
  /// `--mode history|changes|stashes`, `--select-change <path>`, `--select-commit <index>`,
  /// `--all-branches`, `--show-publish` and `--show-branches` set the first repository's view state at launch (or a later
  /// screenshot scene's), for screenshots. Returns once the history they ask for has loaded.
  @MainActor private func applyLaunchArguments(
    _ state: RepositoryViewState, session: RepositorySession
  ) async {
    let scene = LaunchScene.shared
    if let mode = scene.value("--mode").flatMap(RepositoryMode.init(rawValue:)) { state.mode = mode }
    if let path = scene.value("--select-change"), let status = session.status {
      if let change = (status.staged + status.unstaged).first(where: { $0.path == path }) {
        state.selectedChanges = [change.id]
      }
      if status.conflicted.contains(where: { $0.path == path }) { state.selectedConflict = path }
    }
    if scene.flag("--show-publish") { state.isPublishPresented = true }
    if scene.flag("--show-branches") { state.isBranchPopoverPresented = true }
    // The index counts HEAD's history, loaded by `activate`.
    if let index = scene.value("--select-commit").flatMap(Int.init), index < session.commits.count {
      state.selectedCommit = session.commits[index].id
    }
    if scene.flag("--all-branches") {
      session.logQuery = LogQuery(allBranches: true)
      // The query reloads the history in a task of its own.
      try? await Task.sleep(for: .milliseconds(50))
      for _ in 0..<100 where session.isLoadingCommits { try? await Task.sleep(for: .milliseconds(50)) }
    }
  }
#endif

/// The open repository: Changes, History, Stashes, or Resolve Conflicts while a merge, rebase,
/// cherry-pick or revert waits, with the matching title and toolbar.
struct RepositoryScreen: View {
  @Environment(RepositoryLibrary.self) private var library
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  @State private var search = ""
  @State private var gitHubSignIn: GitHubSignInRequest?
  @Environment(GitHubAccount.self) private var gitHub

  private var kind: RepositoryScreenKind {
    switch state.mode {
    case .changes:
      session.status?.operation != nil || state.completedOperation != nil ? .conflicts : .changes
    case .history: .history
    case .stashes: .stashes
    }
  }

  var body: some View {
    ZStack {
      content
        .id(kind)
        .transition(.page)
    }
    .animation(.kit, value: kind)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // The commit toast (Undo, Push), for this repository only.
      .kitToasts()
      .kitToolbar(title) { toolbar.titleView } tools: { toolbar.tools }
      .modifier(HistorySearch(isOn: kind == .history, text: $search, session: session))
      .onChange(of: session.revision) {
        library.updateSummary(session.repository.url.path, from: session)
      }
      .onChange(of: state.mode) { state.completedOperation = nil }
      .sheet(isPresented: $state.isPublishPresented) { PublishRepositorySheet(session: session) }
      .alert(
        session.failure?.title ?? "",
        isPresented: .init(
          get: { session.failure != nil }, set: { if !$0 { session.failure = nil } }),
        presenting: session.failure
      ) { failure in
        // GitHub refuses pushes that change workflows from a token without the workflow scope.
        if failure.message.contains("workflow"), failure.message.contains("scope") {
          Button("Grant Access…") {
            gitHubSignIn = GitHubSignInRequest(
              permissions: gitHub.permissions.union(GitHubPermission.workflows.permissions))
          }
          Button("Cancel", role: .cancel) {}
        } else {
          Button("OK") {}
        }
      } message: { failure in
        Text(failure.message)
      }
      .sheet(item: $gitHubSignIn) { GitHubSignInSheet(permissions: $0.permissions) }
  }

  /// Once the operation is done, the toolbar goes back to the Changes items.
  private var toolbar: RepositoryToolbar {
    RepositoryToolbar(
      session: session, state: state,
      screen: kind == .conflicts && session.status?.operation == nil ? .changes : kind,
      title: title, meta: subtitle, search: kind == .history ? $search : nil)
  }

  @ViewBuilder
  private var content: some View {
    switch kind {
    case .changes: ChangesScreen(session: session, state: state)
    case .history: HistoryScreen(session: session, state: state)
    case .stashes: StashesScreen(session: session)
    case .conflicts: ConflictsScreen(session: session, state: state)
    }
  }

  private var title: String {
    kind == .conflicts && state.completedOperation == nil ? "Resolve Conflicts" : state.mode.title
  }

  private var subtitle: [String] {
    if kind == .conflicts, let operation = session.status?.operation {
      return [OperationText.title(operation, source: session.operationSource, branch: session.status?.branch)]
    }
    // Until the status is in, the sidebar's summary of the repository.
    let summary = session.status.map(RepositorySummary.init) ?? library.summaries[session.repository.url.path]
    let branch = summary?.branch ?? summary?.headOID.map { String($0.prefix(7)) } ?? "No commits"
    switch state.mode {
    case .changes:
      let count = summary?.changeCount ?? 0
      return [branch, count == 0 ? "clean" : "\(count) changed file\(count == 1 ? "" : "s")"]
    case .history, .stashes:
      var parts = [branch]
      if let ahead = summary?.ahead, ahead > 0 { parts.append("\(ahead) commit\(ahead == 1 ? "" : "s") to push") }
      if let behind = summary?.behind, behind > 0 { parts.append("\(behind) to pull") }
      if parts.count == 1 { parts.append(summary?.hasUpstream == true ? "up to date" : "not published") }
      return parts
    }
  }
}

/// History's search (the field is in the toolbar): message, author or hash, as you type.
private struct HistorySearch: ViewModifier {
  let isOn: Bool
  @Binding var text: String
  let session: RepositorySession

  func body(content: Content) -> some View {
    if isOn {
      content
        .task(id: text) {
          // Search as you type, after a short pause.
          try? await Task.sleep(for: .milliseconds(300))
          guard !Task.isCancelled else { return }
          let trimmed = text.trimmingCharacters(in: .whitespaces)
          var query = session.logQuery
          query.search = trimmed.isEmpty ? nil : trimmed
          query.searchField = .any
          if query != session.logQuery { session.logQuery = query }
        }
        .onAppear { text = session.logQuery.search ?? "" }
    } else {
      content
    }
  }
}

/// Titles for an operation in progress: "Merging feature into main".
enum OperationText {
  static func title(_ operation: RepositoryOperation, source: String?, branch: String?) -> String {
    switch (operation, source) {
    case (.merge, let source?): "Merging \(source)" + (branch.map { " into \($0)" } ?? "")
    case (.rebase, let source?): "Rebasing \(source)"
    case (.cherryPick, let source?): "Cherry-picking \(source)"
    case (.revert, let source?): "Reverting \(source)"
    default: operation.title
    }
  }
}
