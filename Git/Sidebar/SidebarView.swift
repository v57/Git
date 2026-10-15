import ComponentKit
import GitKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar: every repository with its state at a glance, then the open repository's
/// Workspace (Changes, History, Stashes), Branches, Remotes and Tags, and a filter at the bottom.
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

  var body: some View {
    @Bindable var library = library
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          RepositoryList(selection: $selection, selected: $selected, filter: filter)
          if let selection {
            RepositorySections(
              session: library.session(for: selection), state: library.viewState(for: selection),
              filter: filter)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 12)
      }
      Divider()
      FilterField(text: $filter, prompt: "Filter")
        .padding(10)
    }
    .overlay {
      if repositories.isEmpty {
        ContentUnavailableView {
          Label("No Repositories", systemImage: "externaldrive.badge.plus")
        } description: {
          Text("Drop a folder here. Every Git repository inside it is added.")
        } actions: {
          Button("Add Folder…") { library.isImporterPresented = true }
        }
      } else if library.isImporting {
        ProgressView("Looking for repositories…")
          .padding()
          .background(.regularMaterial, in: .rect(cornerRadius: 8))
      }
    }
    .overlay {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.accentColor, lineWidth: 2)
          .padding(4)
          .allowsHitTesting(false)
      }
    }
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

  private func matches(_ text: String) -> Bool {
    filter.isEmpty || text.localizedCaseInsensitiveContains(filter)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      workspace
      // The checked-out branch first, as in the Branch popover.
      let branches = session.localBranches.filter { matches($0.name) }
        .sorted { $0.isCurrent && !$1.isCurrent }
      if !branches.isEmpty {
        section("Branches") {
          ForEach(branches) { branch in branchRow(branch) }
        }
      }
      let remotes = session.remotes.filter(matches)
      if !remotes.isEmpty {
        section("Remotes") {
          ForEach(remotes, id: \.self) { remote in
            SidebarRow(title: remote, systemImage: "cloud") {
              if let date = session.lastFetched {
                Text("fetched \(date.agoFormatted)")
                  .font(.system(size: 11))
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            } action: {
              Task { await session.fetch() }
            }
            .help("Fetch \(remote)")
          }
        }
      }
      let tags = session.tags.filter { matches($0.name) }
      if !tags.isEmpty {
        section("Tags") {
          ForEach(tags.prefix(filter.isEmpty ? 12 : 100)) { tag in
            SidebarRow(title: tag.name, systemImage: "tag") {
              EmptyView()
            } action: {
              state.mode = .history
              state.selectedCommit = tag.commit
            }
            .contextMenu {
              Button("Copy Name") { copyToPasteboard(tag.name) }
            }
          }
        }
      }
      if session.worktrees.count > 1 {
        section("Worktrees") {
          ForEach(session.worktrees) { worktree in
            SidebarRow(
              title: worktree.name, systemImage: "folder", isSelected: false,
              isBold: worktree.isCurrent
            ) {
              Text(worktree.branch ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } action: {
              if !worktree.isCurrent { library.open(worktree.url, into: context) }
            }
          }
        }
      }
    }
    .sheet(item: .init(get: { branchStart.map(IdentifiedString.init) }, set: { branchStart = $0?.value })) { start in
      NewBranchSheet(session: session, startPoint: start.value)
    }
    .branchDeletion($pendingDelete, session: session)
  }

  private var workspace: some View {
    section("Workspace") {
      let status = session.status
      let conflicts = status?.conflicted.count ?? 0
      ForEach(RepositoryMode.allCases) { mode in
        SidebarRow(
          title: mode.title, systemImage: mode.systemImage, isSelected: state.mode == mode
        ) {
          switch mode {
          case .changes:
            if conflicts > 0 {
              CountBadge(count: conflicts, filled: .orange)
            } else if let count = status?.changeCount, count > 0 {
              CountBadge(count: count, filled: state.mode == mode ? Color.accentColor : nil)
            }
          case .stashes:
            if !session.stashes.isEmpty { CountBadge(count: session.stashes.count) }
          case .history:
            EmptyView()
          }
        } action: {
          withAnimation(.kit) {
            state.mode = mode
            // Changes again leaves the "Merge complete" screen.
            if mode == .changes { state.completedOperation = nil }
          }
        }
        .keyboardShortcut(mode.shortcut, modifiers: .command)
      }
    }
  }

  private func branchRow(_ branch: Branch) -> some View {
    let status = session.status
    let isMerged = !branch.isCurrent && branch.aheadOfHead == 0 && (branch.behindHead ?? 0) > 0
    let isDeleting = session.deletingBranches.contains(branch.id)
    return SidebarRow(
      title: branch.name, systemImage: SidebarRow<EmptyView>.branchGlyph, isBold: branch.isCurrent
    ) {
      HStack(spacing: 6) {
        if branch.isCurrent {
          if let operation = status?.operation {
            Text(operation.title.lowercased())
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.orange)
          } else {
            if branch.ahead > 0 {
              Text("↑\(branch.ahead)").foregroundStyle(Color.accentColor)
            }
            if branch.behind > 0 {
              Text("↓\(branch.behind)").foregroundStyle(.secondary)
            }
            Image(systemName: "checkmark")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(Color.accentColor)
              .accessibilityLabel("Checked out")
              .transition(.scale.combined(with: .opacity))
          }
        } else if isDeleting {
          HStack(spacing: 4) {
            ProgressView().controlSize(.mini)
            Text("deleting…")
          }
          .foregroundStyle(.secondary)
        } else if isMerged {
          Text("merged").foregroundStyle(.secondary)
        } else if branch.ahead > 0 || branch.behind > 0 {
          Text(
            [branch.ahead > 0 ? "↑\(branch.ahead)" : nil, branch.behind > 0 ? "↓\(branch.behind)" : nil]
              .compactMap { $0 }.joined(separator: " ")
          )
          .foregroundStyle(.secondary)
        }
      }
      .font(.system(size: 11, weight: .medium).monospacedDigit())
      .fixedSize()
      .contentTransition(.numericText())
      .animation(.kit, value: [branch.ahead, branch.behind, branch.isCurrent ? 1 : 0, isDeleting ? 1 : 0])
    } action: {
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
      Button("Copy Name") { copyToPasteboard(branch.name) }
      if !branch.isCurrent {
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = branch }
          .disabled(session.worktree(for: branch) != nil)
      }
    }
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 1) {
      SectionTitle(title)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
      content()
    }
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

// MARK: - Rows

/// A 30-point sidebar row: icon, title and trailing detail. Selected rows are tinted.
struct SidebarRow<Trailing: View>: View {
  /// Pass as `systemImage` to draw the design's git branch glyph instead of a symbol.
  static var branchGlyph: String { "_branch" }

  let title: String
  let systemImage: String
  var isSelected = false
  var isBold = false
  @ViewBuilder var trailing: () -> Trailing
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 9) {
        Group {
          if systemImage == Self.branchGlyph {
            BranchGlyph()
          } else {
            Image(systemName: systemImage)
              .font(.system(size: 13))
              .contentTransition(.symbolEffect(.replace))
          }
        }
        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        .frame(width: 16)
        Text(title)
          .fontWeight(isSelected || isBold ? .semibold : .regular)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 2)
        trailing()
      }
      .foregroundStyle(isSelected ? Color.accentColor : .primary)
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(
        isSelected
          ? Color.accentColor.opacity(0.15) : Color.primary.opacity(isHovered ? 0.05 : 0),
        in: .rect(cornerRadius: 7, style: .continuous)
      )
      .contentShape(.rect(cornerRadius: 7, style: .continuous))
      .animation(.kit, value: isSelected)
      .animation(.kit, value: isHovered)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// A repository's state at a glance: the operation in progress, an orange dot with the number of
/// changed files, ↑ commits to push and ↓ commits to pull. Nothing when it is up to date.
struct StatusMarks: View {
  let summary: RepositorySummary

  var body: some View {
    HStack(spacing: 6) {
      if let operation = summary.operation {
        Text(operation.title)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.orange)
          .padding(.horizontal, 7)
          .frame(height: 18)
          .background(.orange.opacity(0.15), in: .capsule)
      }
      if summary.changeCount > 0 {
        HStack(spacing: 4) {
          Circle().fill(.orange).frame(width: 7, height: 7)
          Text("\(summary.changeCount)")
            .contentTransition(.numericText(value: Double(summary.changeCount)))
        }
        .foregroundStyle(.orange)
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
      }
      if summary.ahead > 0 {
        Text("↑\(summary.ahead)").foregroundStyle(Color.accentColor)
          .contentTransition(.numericText(value: Double(summary.ahead)))
          .transition(.opacity)
      }
      if summary.behind > 0 {
        Text("↓\(summary.behind)").foregroundStyle(.secondary)
          .contentTransition(.numericText(value: Double(summary.behind)))
          .transition(.opacity)
      }
    }
    .font(.system(size: 11, weight: .semibold).monospacedDigit())
    .animation(.kit, value: summary)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.description(summary))
  }

  /// The dot color for a repository's most pressing state.
  static func dotColor(_ summary: RepositorySummary) -> Color {
    if summary.operation != nil || summary.changeCount > 0 { return .orange }
    if summary.ahead > 0 { return .accentColor }
    return .gray
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
