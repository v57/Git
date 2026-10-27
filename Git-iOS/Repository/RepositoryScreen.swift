import ComponentKit
import GitKit
import SwiftUI

/// A repository under the kit's bar: its live title says which branch and what's running; Sync (Fetch, Pull or Push,
/// whichever is useful) and the branch menu lead the bar on iPad and sit in the bottom bar on iPhone. Under it,
/// Changes (the files and the commit composer) or History, each file and commit a push away.
struct RepositoryScreen: View {
  let source: RepositorySource
  @State private var model: RepositoryModel
  @State private var pane = Pane.changes
  @State private var showsNewBranch = false
  @Environment(\.kitIdiom) private var idiom
  @Environment(\.scenePhase) private var scenePhase

  enum Pane: Hashable {
    case changes, history
  }

  init(source: RepositorySource) {
    self.source = source
    _model = State(initialValue: RepositoryModel(source: source))
  }

  var body: some View {
    Group {
      switch model.phase {
      case .connecting(let message):
        EmptyState(systemImage: "desktopcomputer", title: message, status: .working)
      case .failed(let message):
        EmptyState(
          systemImage: "exclamationmark.triangle", title: "Couldn’t Open \(source.name)", message: message,
          status: .failed(nil)
        ) {
          Button("Try Again", systemImage: "arrow.clockwise") { Task { await model.open() } }
            .buttonStyle(.kit)
        }
      case .ready:
        content
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.kitWindow)
    .kitPane(.content)
    .kitToolbar(source.name, title: {
      RepositoryTitle(model: model)
    }) {
      if idiom != .phone, model.phase == .ready {
        SyncTools(model: model)
        BranchTools(model: model, showsNewBranch: $showsNewBranch)
      }
    }
    .modifier(PhoneRepositoryBar(model: idiom == .phone && model.phase == .ready ? model : nil, showsNewBranch: $showsNewBranch))
    .navigationBarBackButtonHidden(true)
    .navigationDestination(for: DiffRoute.self) { route in DiffScreen(model: model, route: route) }
    .navigationDestination(for: Commit.self) { commit in CommitScreen(model: model, commit: commit) }
    .kitSheet(isPresented: $showsNewBranch) { NewBranchSheet(model: model) }
    .kitSheet(item: $model.failure) { failure in MessageSheet(failure.title, message: failure.message) }
    .task {
      await model.open()
      #if DEBUG
        await DebugLaunch.attach(to: model, pane: $pane)
      #endif
      await model.keepFresh()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await model.refresh() } }
    }
    .onDisappear { model.close() }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 12) {
      KitSegmented(
        selection: $pane,
        segments: [
          KitSegment(
            "Changes", value: .changes, count: (model.status?.changeCount).flatMap { $0 == 0 ? nil : $0 }),
          KitSegment("History", value: .history),
        ]
      )
      .kitSegmentedStyle(idiom == .phone ? .wide : .automatic)
      .padding(.horizontal, KitMetrics.gutter + 4)
      switch pane {
      case .changes: ChangesPane(model: model)
      case .history: HistoryPane(model: model)
      }
    }
    .padding(.top, 8)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// The repository's name over its branch and where it is ("main · ↑2 · on studio-mac"), or what's running and its
/// latest progress line; the live icon shows the state.
struct RepositoryTitle: View {
  let model: RepositoryModel

  var body: some View {
    KitTitle(model.source.name, meta: meta, systemImage: "arrow.triangle.branch", hue: .orange, status: status)
  }

  private var status: WorkStatus {
    switch model.phase {
    case .connecting: return .working
    case .failed: return .failed(nil)
    case .ready: return model.isBusy ? .working : .idle
    }
  }

  private var meta: [String] {
    switch model.phase {
    case .connecting(let message): return [message]
    case .failed: return ["Couldn’t open"]
    case .ready: break
    }
    if let activity = model.activity { return [model.progress ?? activity] }
    var parts: [String] = []
    if let status = model.status {
      parts.append(status.branch ?? (status.isDetached ? "Detached HEAD" : "No branch"))
      if status.ahead > 0 { parts.append("↑\(status.ahead)") }
      if status.behind > 0 { parts.append("↓\(status.behind)") }
    }
    switch model.source {
    case .local: parts.append("on this device")
    case .remote: if let target = model.target { parts.append("on \(target.name)") }
    }
    return parts
  }
}

/// Sync: one button that fetches, pulls or pushes, whichever is useful now, with the counts it moves.
struct SyncTools: View {
  let model: RepositoryModel

  var body: some View {
    let action = model.syncAction
    ToolGroup {
      Button {
        Task { await model.sync(action) }
      } label: {
        Label(title(action), systemImage: action.systemImage)
      }
      .disabled(model.isBusy || !model.hasRemote)
    }
  }

  private func title(_ action: RepositoryModel.SyncAction) -> String {
    guard let status = model.status else { return action.title }
    switch action {
    case .pull: return "Pull \(status.behind)"
    case .push: return status.upstream == nil ? "Publish" : "Push \(status.ahead)"
    case .fetch: return "Fetch"
    }
  }
}

/// The current branch as a kit menu: switch to another (a remote one becomes a local branch tracking it), or create
/// one.
struct BranchTools: View {
  let model: RepositoryModel
  @Binding var showsNewBranch: Bool
  @State private var showsBranches = false

  var body: some View {
    ToolGroup {
      Button {
        showsBranches = true
      } label: {
        Label(model.status?.branch ?? "Branch", systemImage: "arrow.triangle.branch")
      }
      .disabled(model.isBusy)
      .kitMenu(isPresented: $showsBranches) {
        KitMenuSection("Branches") {
          ForEach(model.localBranches) { branch in
            Button {
              if !branch.isCurrent { Task { await model.switchTo(branch) } }
            } label: {
              Label(branch.name, systemImage: branch.isCurrent ? "checkmark" : "arrow.triangle.branch")
            }
          }
        }
        let local = Set(model.localBranches.map(\.name))
        let remoteOnly = model.remoteBranches.filter { !local.contains($0.localName) && $0.localName != "HEAD" }
        if !remoteOnly.isEmpty {
          KitMenuSection("Remote") {
            ForEach(remoteOnly) { branch in
              Button(branch.name, systemImage: "cloud") { Task { await model.switchTo(branch) } }
            }
          }
        }
        Divider()
        Button("New Branch…", systemImage: "plus") { showsNewBranch = true }
      }
    }
    .lineLimit(1)
  }
}

/// iPhone: Sync and the branch menu in the bottom bar.
private struct PhoneRepositoryBar: ViewModifier {
  let model: RepositoryModel?
  @Binding var showsNewBranch: Bool

  func body(content: Content) -> some View {
    if let model {
      content.kitBottomBar(searchText: nil) {
        BranchTools(model: model, showsNewBranch: $showsNewBranch)
        Spacer(minLength: 0)
        SyncTools(model: model)
      }
    } else {
      content
    }
  }
}

/// A file's diff to push: what changed in the working tree, the index or a commit.
struct DiffRoute: Hashable {
  var target: DiffTarget
  /// The file's change in Changes (for Stage, Unstage and Discard), nil for a commit's file.
  var change: FileChange?
  var kind: ChangeKind
}
