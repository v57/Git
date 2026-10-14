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
  @SceneStorage("selectedRepository") private var selectedPath: String?

  var body: some View {
    @Bindable var library = library
    NavigationSplitView {
      SidebarView(selection: $selectedPath)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
    } detail: {
      if let path = selectedPath {
        ZStack {
          RepositoryScreen(session: library.session(for: path), state: library.viewState(for: path))
            .id(path)
            // No rise: moving the whole screen makes the toolbar's glass border blink.
            .transition(.opacity)
        }
        .animation(.app, value: path)
      } else {
        ContentUnavailableView {
          Label("No Repository Selected", systemImage: "folder")
        } description: {
          Text("Choose a repository in the sidebar.")
        } actions: {
          Button("Show Welcome Window") { openWindow(id: WelcomeWindow.id) }
        }
        .navigationTitle("Git")
      }
    }
    .frame(minWidth: 1100, minHeight: 600)
    .tracking(.designTracking)
    .onChange(of: library.requestedSelection, initial: true) { _, path in
      guard let path else { return }
      selectedPath = path
      library.requestedSelection = nil
    }
    .focusedSceneValue(\.repositorySession, selectedPath.map(library.session(for:)))
    .focusedSceneValue(\.repositoryViewState, selectedPath.map(library.viewState(for:)))
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
    .task(id: selectedPath) {
      await library.activate(selectedPath, context: context)
      #if DEBUG
        if let path = selectedPath { applyLaunchArguments(library.viewState(for: path), session: library.session(for: path)) }
      #endif
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task {
        if let path = selectedPath { await library.session(for: path).refresh() }
        await library.refreshAllSummaries()
      }
    }
  }
}

#if DEBUG
  /// `--mode history|changes|stashes`, `--select-change <path>`, `--select-commit <index>`,
  /// `--all-branches` and `--show-publish` set the first repository's view state at launch, for
  /// screenshots.
  @MainActor private func applyLaunchArguments(
    _ state: RepositoryViewState, session: RepositorySession
  ) {
    let arguments = ProcessInfo.processInfo.arguments
    func value(_ name: String) -> String? {
      arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }
    if let mode = value("--mode").flatMap(RepositoryMode.init(rawValue:)) { state.mode = mode }
    if let path = value("--select-change"), let status = session.status {
      if let change = (status.staged + status.unstaged).first(where: { $0.path == path }) {
        state.selectedChanges = [change.id]
      }
      if status.conflicted.contains(where: { $0.path == path }) { state.selectedConflict = path }
    }
    if arguments.contains("--show-publish") { state.isPublishPresented = true }
    if arguments.contains("--all-branches") {
      session.logQuery = LogQuery(allBranches: true)
    }
    if let index = value("--select-commit").flatMap(Int.init), index < session.commits.count {
      state.selectedCommit = session.commits[index].id
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
    .animation(.app, value: kind)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle(title)
      .navigationSubtitle(subtitle)
      // Once the operation is done, the toolbar goes back to the Changes items.
      .toolbar {
        RepositoryToolbar(
          session: session, state: state,
          screen: kind == .conflicts && session.status?.operation == nil ? .changes : kind)
      }
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

  private var subtitle: String {
    let branch = session.status?.branch ?? session.status?.headOID.map { String($0.prefix(7)) } ?? "No commits"
    if kind == .conflicts, let operation = session.status?.operation {
      return OperationText.title(operation, source: session.operationSource, branch: session.status?.branch)
    }
    let status = session.status
    switch state.mode {
    case .changes:
      let count = status?.changeCount ?? 0
      return count == 0 ? "\(branch) · clean" : "\(branch) · \(count) changed file\(count == 1 ? "" : "s")"
    case .history, .stashes:
      var parts = [branch]
      if let ahead = status?.ahead, ahead > 0 { parts.append("\(ahead) commit\(ahead == 1 ? "" : "s") to push") }
      if let behind = status?.behind, behind > 0 { parts.append("\(behind) to pull") }
      if parts.count == 1 { parts.append(status?.upstream == nil ? "not published" : "up to date") }
      return parts.joined(separator: " · ")
    }
  }
}

/// The toolbar search field of History: message, author or hash.
private struct HistorySearch: ViewModifier {
  let isOn: Bool
  @Binding var text: String
  let session: RepositorySession

  func body(content: Content) -> some View {
    if isOn {
      content
        .searchable(text: $text, placement: .toolbar, prompt: "Message, author, hash")
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
