import ComponentKit
import GitKit
import SwiftData
import SwiftUI
import VaultKit

/// Every repository on one page, grouped by folder: a grid of cards (or a list) with each one's branch, last commit
/// and its time, and its changes, commits to push and to pull. Search narrows it by name, folder or branch; Fetch All
/// fetches every repository shown. Clicking one opens it. The sidebar's Repositories header opens the page.
struct AllRepositoriesView: View {
  @Environment(RepositoryLibrary.self) private var library
  @Query(sort: \SavedRepository.name, order: .forward) private var repositories: [SavedRepository]
  @Binding var selection: String?
  @AppStorage("AllRepositoriesLayout") private var layout = AllRepositoriesLayout.grid
  @State private var search = ""

  var body: some View {
    let folders = folders
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 22) {
        ForEach(folders) { folder in
          FolderBlock(folder: folder, layout: layout, open: open)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .overlay {
      if folders.isEmpty {
        EmptyState(
          systemImage: "magnifyingglass", title: "No Repositories",
          message: search.isEmpty ? "Add a folder from the sidebar." : "Nothing matches “\(search)”.")
      }
    }
    .kitPane(.content)
    .kitToolbar(title) { titleView } tools: { tools }
  }

  private var title: String { "All Repositories" }

  private var titleView: KitTitle {
    let shown = repositories.filter { !$0.isHidden }
    let summaries = shown.compactMap { library.summaries[$0.path] }
    let changed = summaries.count { $0.changeCount > 0 || $0.operation != nil }
    let toPush = summaries.count { $0.ahead > 0 }
    return KitTitle(
      title,
      meta: [
        shown.count == 1 ? "1 repository" : "\(shown.count) repositories",
        changed > 0 ? "\(changed) with changes" : "", toPush > 0 ? "\(toPush) to push" : "",
      ],
      systemImage: "square.grid.2x2", hue: .indigo, status: isFetching ? .working : .idle)
  }

  @ToolbarSlotBuilder private var tools: [ToolbarSlot] {
    ToolGroup(iconOnly: true) {
      Button("Grid", systemImage: "square.grid.2x2") { withKitAnimation { layout = .grid } }
        .kitToolOn(layout == .grid)
      Button("List", systemImage: "list.bullet") { withKitAnimation { layout = .list } }
        .kitToolOn(layout == .list)
    }
    ToolGroup {
      Button("Fetch All", systemImage: "arrow.clockwise") {
        let paths = folders.flatMap(\.repositories).map(\.path)
        Task { await library.run(.fetch, on: paths) }
      }
      .disabled(isFetching)
      .help("Fetch every repository shown")
      Button("Clone", systemImage: "plus") { library.isClonePresented = true }
        .help("Clone a repository")
    }
    KitSearchField(text: $search, prompt: "Name, folder, branch").frame(width: 220)
  }

  private var isFetching: Bool { !library.remoteActivity.isEmpty }

  private func open(_ path: String) {
    selection = path
    withKitAnimation { library.showsAllRepositories = false }
  }

  /// The repositories by folder: every folder of the sidebar, nested ones after their parent ("Hub › Services"),
  /// each with the repositories directly in it, then the ones in no folder.
  private var folders: [RepositoryFolder] {
    let sidebar = SidebarLayout(repositories: repositories, vault: library.vault)
    let device = library.vault.deviceID
    var folders: [RepositoryFolder] = []
    var loose: [SavedRepository] = []
    func walk(_ groupID: String?) {
      var direct: [SavedRepository] = []
      var groups: [VaultProjectGroup] = []
      for item in sidebar.children(of: groupID) {
        switch item {
        case .repository(let repository): direct.append(repository)
        case .group(let group): groups.append(group)
        }
      }
      if let groupID, let group = sidebar.tree.groups.first(where: { $0.id == groupID }) {
        folders.append(
          RepositoryFolder(
            id: group.id, name: sidebar.title(of: group), path: group.paths[device].map(Self.abbreviated),
            repositories: direct.filter(matches).map { card($0, sidebar) }))
      } else {
        loose = direct
      }
      for group in groups { walk(group.id) }
    }
    walk(nil)
    folders.append(
      RepositoryFolder(
        id: "other", name: "Other", path: nil, repositories: loose.filter(matches).map { card($0, sidebar) }))
    return folders.filter { !$0.repositories.isEmpty }
  }

  private func matches(_ repository: SavedRepository) -> Bool {
    guard !repository.isHidden else { return false }
    let query = search.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return true }
    let branch = library.summaries[repository.path]?.branch ?? ""
    return repository.name.localizedCaseInsensitiveContains(query)
      || repository.groupName.localizedCaseInsensitiveContains(query) || branch.localizedCaseInsensitiveContains(query)
  }

  private func card(_ repository: SavedRepository, _ sidebar: SidebarLayout) -> RepositoryCardModel {
    RepositoryCardModel(
      path: repository.path, name: repository.name, icon: sidebar.icon(of: repository.path),
      summary: library.summaries[repository.path], activity: library.activities[repository.path],
      isBusy: library.remoteActivity[repository.path] != nil, exists: repository.exists)
  }

  /// "~/Developer/v57" for a folder in the home folder.
  static func abbreviated(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }
}

enum AllRepositoriesLayout: String {
  case grid, list
}

/// A folder of the page: its repositories in the sidebar's order.
struct RepositoryFolder: Identifiable {
  let id: String
  let name: String
  let path: String?
  let repositories: [RepositoryCardModel]
}

/// What a card shows of a repository.
struct RepositoryCardModel: Identifiable {
  let path: String
  let name: String
  let icon: Data?
  let summary: RepositorySummary?
  let activity: RepositoryActivity?
  let isBusy: Bool
  let exists: Bool
  var id: String { path }

  /// "main · today": the branch and when it was last committed to.
  var meta: [String] {
    [summary?.branchLabel ?? "", activity?.lastCommit.map(\.relativeDay) ?? ""]
  }
}

/// A folder's title and its repositories, as cards or as rows.
private struct FolderBlock: View {
  let folder: RepositoryFolder
  let layout: AllRepositoriesLayout
  let open: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(folder.name).kitFont(.headline)
        Text(([folder.path].compactMap { $0 } + ["\(folder.repositories.count)"]).joined(separator: " · "))
          .kitFont(.caption)
          .lineLimit(1)
      }
      .padding(.leading, 4)
      switch layout {
      case .grid:
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: KitMetrics.gutter)], spacing: KitMetrics.gutter) {
          ForEach(folder.repositories) { repository in
            RepositoryCard(repository: repository) { open(repository.path) }
          }
        }
      case .list:
        VStack(spacing: 2) {
          ForEach(folder.repositories) { repository in
            RepositoryListRow(repository: repository) { open(repository.path) }
          }
        }
        .padding(KitMetrics.cardPadding)
        .kitSurface(.card)
      }
    }
  }
}

/// A repository as a card: its icon, name, branch and last commit's time, the commit's subject, and its counts.
private struct RepositoryCard: View {
  let repository: RepositoryCardModel
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .top, spacing: 8) {
          RepositoryIcon(repository: repository, size: 28)
          VStack(alignment: .leading, spacing: 1) {
            Text(repository.name).kitFont(.headline).lineLimit(1)
            MetaLine(repository.meta)
          }
          Spacer(minLength: 4)
          RepositoryCounts(repository: repository)
        }
        Text(repository.activity?.lastCommitSubject ?? (repository.exists ? "No commits" : "Missing"))
          .kitFont(.caption)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      // Under the pointer the card rises, as a row's selection does.
      .kitSurface(isHovered ? .raised : .card, cornerRadius: KitMetrics.radiusCard)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.kitFast, value: isHovered)
    .help(repository.path)
    .accessibilityLabel(repository.name)
  }
}

/// A repository as a row of the list layout.
private struct RepositoryListRow: View {
  let repository: RepositoryCardModel
  let action: () -> Void

  var body: some View {
    SidebarRow(repository.name) {
      RepositoryIcon(repository: repository, size: 18)
    } trailing: {
      HStack(spacing: 10) {
        Text(repository.activity?.lastCommitSubject ?? "").lineLimit(1).frame(maxWidth: 320, alignment: .trailing)
        RepositoryCounts(repository: repository)
      }
    }
    .subtitle { MetaLine(repository.meta) }
    .action(action)
    .help(repository.path)
  }
}

private struct RepositoryIcon: View {
  let repository: RepositoryCardModel
  let size: CGFloat

  var body: some View {
    let status: WorkStatus = repository.isBusy ? .working : .idle
    if let image = repository.icon.flatMap(Image.init(data:)) {
      Avatar(name: repository.name, image: image, kind: .thing, status: status, size: size)
    } else {
      Avatar(name: repository.name, kind: .thing, status: status, size: size)
    }
  }
}

/// Changes, ↑ and ↓, or the operation in progress.
private struct RepositoryCounts: View {
  let repository: RepositoryCardModel

  var body: some View {
    if let summary = repository.summary {
      StatusMarks(summary: summary).fixedSize()
    }
  }
}

extension Date {
  /// "today", "yesterday", "3 days", "last week", "4 weeks", "Mar 2024": how long ago, in days or more.
  var relativeDay: String {
    let calendar = Calendar.current
    if calendar.isDateInToday(self) { return "today" }
    if calendar.isDateInYesterday(self) { return "yesterday" }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: self), to: calendar.startOfDay(for: .now))
      .day ?? 0
    if days < 7 { return "\(days) days" }
    if days < 14 { return "last week" }
    if days < 60 { return "\(days / 7) weeks" }
    return formatted(.dateTime.month(.abbreviated).year())
  }
}
