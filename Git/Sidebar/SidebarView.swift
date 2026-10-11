import GitKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar: every repository with its state at a glance, then the open repository's
/// Workspace (Changes, History, Stashes), Branches, Remotes and Tags, and a filter at the bottom.
///
/// Dropping a folder (or picking one with +) adds every git repository inside it. Repository
/// states come from a file watcher over all of them. Collapsed, Repositories keeps the open one
/// visible and shows an icon for each other repository that needs attention.
struct SidebarView: View {
  @Environment(RepositoryLibrary.self) private var library
  @Environment(\.modelContext) private var context
  @Query(sort: \SavedRepository.name, order: .forward) private var repositories: [SavedRepository]
  @Binding var selection: String?
  @State private var isDropTargeted = false
  @State private var filter = ""
  @AppStorage("RepositoriesCollapsed") private var isCollapsed = false

  /// Most recently opened first, as in the Welcome window's Recent list.
  private var sorted: [SavedRepository] {
    repositories.sorted {
      let lhs = $0.lastOpenedAt ?? .distantPast
      let rhs = $1.lastOpenedAt ?? .distantPast
      if lhs != rhs { return lhs > rhs }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  private func matches(_ text: String) -> Bool {
    filter.isEmpty || text.localizedCaseInsensitiveContains(filter)
  }

  var body: some View {
    @Bindable var library = library
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          repositoriesSection
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
      importFolders(urls)
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
    .task(id: repositories.map(\.path)) {
      library.watchSummaries(of: repositories.map(\.path))
      #if DEBUG
        // --add-folder <path> (repeatable) imports folders at launch, for testing.
        let arguments = ProcessInfo.processInfo.arguments
        let folders = arguments.indices.dropLast().filter { arguments[$0] == "--add-folder" }
          .map { URL(fileURLWithPath: arguments[$0 + 1]) }
        if !folders.isEmpty, repositories.isEmpty { importFolders(folders) }
      #endif
      await library.refreshSummaries(repositories.map(\.path))
    }
  }

  // MARK: Repositories

  private var repositoriesSection: some View {
    let others = sorted.filter { $0.path != selection }
    let attention = others.compactMap { repository in
      library.summaries[repository.path].flatMap { $0.needsAttention ? (repository.name, $0) : nil }
    }
    let visible = sorted.filter { (!isCollapsed || $0.path == selection) && matches($0.name) }
    return VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 2) {
        Button {
          withAnimation(.app) { isCollapsed.toggle() }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.right")
              .font(.system(size: 8, weight: .heavy))
              .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            SectionTitle("Repositories")
            Spacer(minLength: 4)
            if isCollapsed {
              AttentionIcons(items: attention)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
          }
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .frame(height: 24)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(attentionHelp(attention))
        .accessibilityLabel(isCollapsed ? "Expand Repositories" : "Collapse Repositories")
        Button {
          library.isImporterPresented = true
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Add the Git repositories in a folder")
        .accessibilityLabel("Add Repository")
      }
      ForEach(visible) { repository in
        RepositoryRow(
          repository: repository, summary: library.summaries[repository.path],
          isCurrent: repository.path == selection
        ) {
          selection = repository.path
        }
        .contextMenu { repositoryMenu(repository) }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .animation(.app, value: visible.map(\.path))
    .animation(.app, value: selection)
  }

  private func attentionHelp(_ items: [(name: String, summary: RepositorySummary)]) -> String {
    guard isCollapsed, !items.isEmpty else { return isCollapsed ? "All other repositories are up to date" : "" }
    return items.map { "\($0.name): \(StatusMarks.description($0.summary))" }.joined(separator: "\n")
  }

  @ViewBuilder
  private func repositoryMenu(_ repository: SavedRepository) -> some View {
    Button("Show in Finder") { RepositoryLibrary.reveal(repository.url) }
    Button("Open in Terminal") { RepositoryLibrary.openInTerminal(repository.url) }
    Divider()
    Button("Remove from List") {
      if selection == repository.path { selection = nil }
      library.remove([repository], from: context)
    }
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
    .confirmationDialog(
      "Delete \(pendingDelete?.name ?? "")?",
      isPresented: .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        if let branch = pendingDelete { Task { await session.deleteBranch(branch) } }
      }
      Button("Force Delete", role: .destructive) {
        if let branch = pendingDelete { Task { await session.deleteBranch(branch, force: true) } }
      }
    } message: {
      Text("Delete refuses a branch that isn't merged; Force Delete removes it anyway.")
    }
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
          withAnimation(.app) {
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
      .animation(.app, value: [branch.ahead, branch.behind, branch.isCurrent ? 1 : 0])
    } action: {
      if let worktree = session.worktree(for: branch) {
        library.open(worktree.url, into: context)
      } else if !branch.isCurrent {
        Task { await session.switchTo(branch) }
      }
    }
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
      .animation(.app, value: isSelected)
      .animation(.app, value: isHovered)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// A repository: icon, name and state. The open one is a raised card.
private struct RepositoryRow: View {
  let repository: SavedRepository
  let summary: RepositorySummary?
  let isCurrent: Bool
  let select: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: select) {
      HStack(spacing: 9) {
        RepositoryIcon(name: repository.name, size: 18)
        Text(repository.name)
          .fontWeight(isCurrent ? .semibold : .regular)
          .lineLimit(1)
        Spacer(minLength: 4)
        if !repository.exists {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .help("Missing")
        } else if let summary {
          StatusMarks(summary: summary)
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 30)
      .animation(.app, value: isCurrent)
      .animation(.app, value: isHovered)
      .background {
        if isCurrent {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
        } else if isHovered {
          RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05))
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help("\(repository.path)\n\(summary.map(StatusMarks.description) ?? "")")
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
  }
}

/// Icons with a status dot for repositories that need attention, in the collapsed header.
private struct AttentionIcons: View {
  let items: [(name: String, summary: RepositorySummary)]

  var body: some View {
    HStack(spacing: 6) {
      ForEach(items.prefix(5), id: \.name) { item in
        RepositoryIcon(name: item.name, size: 16)
          .overlay(alignment: .topTrailing) {
            Circle()
              .fill(StatusMarks.dotColor(item.summary))
              .frame(width: 8, height: 8)
              .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
              .offset(x: 3, y: -3)
          }
      }
      if items.count > 5 {
        Text("+\(items.count - 5)")
          .font(.caption2.weight(.semibold))
      }
    }
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
    .animation(.app, value: summary)
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
