import GitKit
import SwiftData
import SwiftUI

struct ContentView: View {
  @Environment(RepositoryLibrary.self) private var library
  @Environment(\.scenePhase) private var scenePhase
  @SceneStorage("selectedRepository") private var selectedPath: String?

  var body: some View {
    NavigationSplitView {
      SidebarView(selection: $selectedPath)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
    } content: {
      if let path = selectedPath {
        RepositoryColumn(session: library.session(for: path), state: library.viewState(for: path))
          .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 520)
      } else {
        ContentUnavailableView("No Repository Selected", systemImage: "folder")
          .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 520)
      }
    } detail: {
      if let path = selectedPath {
        RepositoryDetail(session: library.session(for: path), state: library.viewState(for: path))
      } else {
        Color.clear
      }
    }
    .toolbar {
      if let path = selectedPath {
        RepositoryToolbar(session: library.session(for: path))
      }
    }
    .frame(minWidth: 960, minHeight: 560)
    .navigationTitle(selectedPath.map { ($0 as NSString).lastPathComponent } ?? "Git")
    .focusedSceneValue(\.repositorySession, selectedPath.map(library.session(for:)))
    .task(id: selectedPath) {
      await library.activate(selectedPath)
      #if DEBUG
        if let path = selectedPath { applyLaunchArguments(library.viewState(for: path), session: library.session(for: path)) }
      #endif
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active, let path = selectedPath else { return }
      Task { await library.session(for: path).refresh() }
    }
  }
}

#if DEBUG
  /// `--mode history|changes`, `--select-change <path>` and `--select-commit <index>` set the
  /// first repository's view state at launch, for screenshots.
  @MainActor private func applyLaunchArguments(
    _ state: RepositoryViewState, session: RepositorySession
  ) {
    let arguments = ProcessInfo.processInfo.arguments
    func value(_ name: String) -> String? {
      arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }
    if let mode = value("--mode").flatMap(RepositoryMode.init(rawValue:)) { state.mode = mode }
    if let path = value("--select-change"), let status = session.status,
      let change = (status.staged + status.unstaged).first(where: { $0.path == path })
    {
      state.selectedChanges = [change.id]
    }
    if let index = value("--select-commit").flatMap(Int.init), index < session.commits.count {
      state.selectedCommit = session.commits[index].id
    }
  }
#endif

/// The middle column: the changes list with the commit composer, or the history list.
struct RepositoryColumn: View {
  @Environment(RepositoryLibrary.self) private var library
  let session: RepositorySession
  @Bindable var state: RepositoryViewState

  var body: some View {
    Group {
      switch state.mode {
      case .changes: ChangesView(session: session, state: state)
      case .history: HistoryView(session: session, state: state)
      }
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Mode", selection: $state.mode) {
          ForEach(RepositoryMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
    }
    .onChange(of: session.revision) {
      library.updateSummary(session.repository.url.path, from: session)
    }
    .alert(
      session.failure?.title ?? "", isPresented: .init(
        get: { session.failure != nil }, set: { if !$0 { session.failure = nil } }),
      presenting: session.failure
    ) { _ in
      Button("OK") {}
    } message: { failure in
      Text(failure.message)
    }
  }
}

/// The detail column: the diff of the selected change, or the selected commit.
struct RepositoryDetail: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState

  var body: some View {
    switch state.mode {
    case .changes:
      ChangeDetailView(session: session, state: state)
    case .history:
      if let id = state.selectedCommit, let commit = session.commits.first(where: { $0.id == id }) {
        CommitDetailView(session: session, commit: commit, state: state)
          .id(commit.id)
      } else {
        ContentUnavailableView("No Commit Selected", systemImage: "clock")
      }
    }
  }
}
