import ComponentKit
import GitKit
import SwiftData
import SwiftUI

/// The Repositories section: groups (one level) and repositories in the order they were dragged
/// into, each with its state at a glance; a group's header sums up its repositories.
///
/// Click opens a repository; ⌘-click and ⇧-click select several for the context menu (Fetch,
/// Pull, Push, Hide, Move to Group) and for dragging. Collapsed, the section keeps the open
/// repository visible and shows an icon for each other repository that needs attention.
struct RepositoryList: View {
  @Environment(RepositoryLibrary.self) private var library
  @Environment(\.modelContext) private var context
  @Query private var repositories: [SavedRepository]
  @Query private var groups: [SavedGroup]
  @Binding var selection: String?
  @Binding var selected: Set<String>
  let filter: String
  @State private var anchor: String?
  @State private var dropTarget: String?
  @State private var renaming: SavedGroup?
  @State private var newName = ""
  @AppStorage("RepositoriesCollapsed") private var isCollapsed = false
  @AppStorage("ShowsHiddenRepositories") private var showsHidden = false

  private var layout: SidebarLayout { SidebarLayout(repositories: repositories, groups: groups) }

  private func isShown(_ repository: SavedRepository) -> Bool {
    (showsHidden || !repository.isHidden || repository.path == selection)
      && (filter.isEmpty || repository.name.localizedCaseInsensitiveContains(filter))
  }

  /// What is on screen, top to bottom: top-level items, and the shown members of open groups.
  private func visibleRows(_ layout: SidebarLayout) -> [(item: SidebarItem, members: [SavedRepository])] {
    layout.items.compactMap { item in
      switch item {
      case .repository(let repository):
        return isShown(repository) ? (item, []) : nil
      case .group(let group):
        let all = layout.members[group.id] ?? []
        let groupMatches = !filter.isEmpty && group.name.localizedCaseInsensitiveContains(filter)
        let members = all.filter {
          (showsHidden || !$0.isHidden || $0.path == selection)
            && (groupMatches || isShown($0))
        }
        guard !members.isEmpty else { return nil }
        return (item, group.isCollapsed && filter.isEmpty ? [] : members)
      }
    }
  }

  /// Repository paths in screen order, for ⇧-click ranges and for dragging several.
  private func order(_ layout: SidebarLayout) -> [String] {
    visibleRows(layout).flatMap { row in
      if case .repository(let repository) = row.item { [repository.path] } else { row.members.map(\.path) }
    }
  }

  var body: some View {
    let layout = layout
    let rows = visibleRows(layout)
    let hiddenCount = repositories.count { $0.isHidden }
    KitSection(
      "Repositories", meta: meta, systemImage: "folder", hue: .indigo,
      status: library.isImporting ? .working : .idle,
      isExpanded: .init(get: { !isCollapsed }, set: { isCollapsed = !$0 })
    ) {
      ForEach(rows, id: \.item.id) { row in
        switch row.item {
        case .repository(let repository):
          repositoryRow(repository, layout: layout)
        case .group(let group):
          groupHeader(group, members: layout.members[group.id] ?? [], layout: layout)
          ForEach(row.members) { repository in
            repositoryRow(repository, layout: layout)
              .kitRowIndent(1)
          }
        }
      }
      // Dropping below the last row moves to the end of the top level.
      Color.clear
        .frame(height: 6)
        .overlay(alignment: .top) { InsertionLine(isShown: dropTarget == "end") }
        .dropDestination(for: URL.self) { urls, _ in
          drop(urls, into: nil, before: nil, layout: layout)
        } isTargeted: { setTarget("end", $0) }
      if hiddenCount > 0 && filter.isEmpty {
        Button(showsHidden ? "Hide Hidden Repositories" : "Show \(hiddenCount) Hidden") {
          withKitAnimation { showsHidden.toggle() }
        }
        .buttonStyle(.kitPlain)
        .controlSize(.small)
        .padding(.leading, 4)
      }
    } accessory: {
      Button("Add Repository", systemImage: "plus") { library.isImporterPresented = true }
        .help("Add the Git repositories in a folder")
    }
    .help(attentionHelp)
    .animation(.kit, value: rows.map(\.item.id))
    .animation(.kit, value: rows.flatMap { $0.members.map(\.path) })
    .onChange(of: selection, initial: true) { _, path in
      if let path, !selected.contains(path) || selected.count == 1 {
        selected = [path]
        anchor = path
      }
    }
    .alert(
      "Rename Group",
      isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    ) {
      TextField("Name", text: $newName)
      Button("Rename") {
        let name = newName.trimmingCharacters(in: .whitespaces)
        if let group = renaming, !name.isEmpty {
          group.name = name
          try? context.save()
        }
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  // MARK: Header

  /// "5 repositories · 2 with changes", or what the import is doing.
  private var meta: [String] {
    if library.isImporting { return ["Looking for repositories…"] }
    let shown = repositories.filter { !$0.isHidden }
    let attention = shown.count { library.summaries[$0.path]?.needsAttention == true }
    return [
      shown.count == 1 ? "1 repository" : "\(shown.count) repositories",
      attention > 0 ? "\(attention) with changes" : "",
    ]
  }

  /// The other repositories that need attention, for the collapsed section's tooltip.
  private var attentionHelp: String {
    guard isCollapsed else { return "" }
    let lines = SidebarLayout.ordered(repositories.filter { $0.path != selection && !$0.isHidden })
      .compactMap { repository in
        library.summaries[repository.path].flatMap {
          $0.needsAttention ? "\(repository.name): \(StatusMarks.description($0))" : nil
        }
      }
    return lines.isEmpty ? "All other repositories are up to date" : lines.joined(separator: "\n")
  }

  // MARK: Groups

  private func groupHeader(_ group: SavedGroup, members: [SavedRepository], layout: SidebarLayout)
    -> some View
  {
    let visible = members.filter { !$0.isHidden }
    let summaries = visible.compactMap { library.summaries[$0.path] }
    let id = SidebarItem.id(of: group)
    return GroupHeader(
      group: group, summary: RepositorySummary(combining: summaries),
      isBusy: members.contains { library.remoteActivity[$0.path] != nil },
      isTargeted: dropTarget == id,
      help: groupHelp(group, members: visible)
    ) {
      withAnimation(.kit) { group.isCollapsed.toggle() }
      try? context.save()
    }
    .draggable(SidebarItem.dragURL(for: group)) {
      DragPreview(title: group.name, count: nil)
    }
    .dropDestination(for: URL.self) { urls, _ in
      drop(urls, into: group.id, before: nil, groupBefore: id, layout: layout)
    } isTargeted: { setTarget(id, $0) }
    .kitContextMenu { groupMenu(group, members: members) }
  }

  private func groupHelp(_ group: SavedGroup, members: [SavedRepository]) -> String {
    let lines = members.compactMap { repository in
      library.summaries[repository.path].flatMap {
        $0.needsAttention ? "\(repository.name): \(StatusMarks.description($0))" : nil
      }
    }
    let title = group.directory.isEmpty ? group.name : group.directory
    let count = members.count == 1 ? "1 repository" : "\(members.count) repositories"
    return ([title, count] + lines).joined(separator: "\n")
  }

  @ViewBuilder
  private func groupMenu(_ group: SavedGroup, members: [SavedRepository]) -> some View {
    let paths = members.map(\.path)
    remoteButtons(paths, suffix: " All")
    Divider()
    Button("Rename…", systemImage: "pencil") {
      newName = group.name
      renaming = group
    }
    Button("Ungroup", systemImage: "folder.badge.minus") { library.ungroup(group, context: context) }
    Divider()
    if !group.directory.isEmpty {
      Button("Show in Finder", systemImage: "folder") {
        RepositoryLibrary.reveal(URL(fileURLWithPath: group.directory, isDirectory: true))
      }
      Divider()
    }
    if members.allSatisfy(\.isHidden) {
      Button("Unhide Group", systemImage: "eye") { library.setHidden(paths, false, context: context) }
    } else {
      Button("Hide Group", systemImage: "eye.slash") { library.setHidden(paths, true, context: context) }
    }
  }

  // MARK: Repositories

  private func repositoryRow(_ repository: SavedRepository, layout: SidebarLayout) -> some View {
    let isMulti = selected.count > 1 && selected.contains(repository.path)
    return RepositoryRow(
      repository: repository, summary: library.summaries[repository.path],
      isCurrent: repository.path == selection, isSelected: isMulti,
      activity: library.remoteActivity[repository.path], outcome: library.remoteOutcomes[repository.path]
    ) {
      click(repository.path, layout: layout)
    }
    .opacity(repository.isHidden ? 0.5 : 1)
    .overlay(alignment: .top) { InsertionLine(isShown: dropTarget == repository.path) }
    .draggable(repository.url) {
      DragPreview(title: repository.name, count: isMulti ? selected.count : nil)
    }
    .dropDestination(for: URL.self) { urls, _ in
      drop(
        urls, into: repository.groupID, before: repository.path,
        groupBefore: repository.groupID.flatMap { id in groups.first { $0.id == id } }
          .map(SidebarItem.id(of:)) ?? repository.path,
        layout: layout)
    } isTargeted: { setTarget(repository.path, $0) }
    .kitContextMenu { repositoryMenu(targets(for: repository.path, layout: layout)) }
    .transition(.row)
  }

  /// The repositories a context menu or drag acts on: the selection when the row is in it.
  private func targets(for path: String, layout: SidebarLayout) -> [String] {
    guard selected.count > 1, selected.contains(path) else { return [path] }
    return order(layout).filter(selected.contains)
  }

  /// Click opens; ⌘-click adds or removes; ⇧-click selects the range from the last click.
  private func click(_ path: String, layout: SidebarLayout) {
    let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
    if flags.contains(.command) {
      if selected.contains(path) {
        if selected.count > 1 { selected.remove(path) }
      } else {
        selected.insert(path)
      }
      anchor = path
    } else if flags.contains(.shift), let start = anchor ?? selection {
      let order = order(layout)
      guard let from = order.firstIndex(of: start), let to = order.firstIndex(of: path) else { return }
      selected = Set(order[min(from, to)...max(from, to)])
    } else {
      selected = [path]
      anchor = path
      selection = path
    }
  }

  @ViewBuilder
  private func repositoryMenu(_ paths: [String]) -> some View {
    let targets = paths.compactMap { path in repositories.first { $0.path == path } }
    let suffix = targets.count > 1 ? " \(targets.count) Repositories" : ""
    remoteButtons(paths, suffix: suffix)
    Divider()
    KitSubmenu("Move to Group", systemImage: "folder") {
      ForEach(SidebarLayout.ordered(groups.map(SidebarItem.group)), id: \.id) { item in
        if case .group(let group) = item {
          Button(group.note.isEmpty ? group.name : "\(group.name) (\(group.note))") {
            library.move(paths, into: group.id, before: nil, context: context)
          }
          .disabled(targets.allSatisfy { $0.groupID == group.id })
        }
      }
      if !groups.isEmpty { Divider() }
      Button("New Group…", systemImage: "folder.badge.plus") {
        if let group = library.newGroup(from: paths, context: context) {
          newName = group.name
          renaming = group
        }
      }
    }
    if targets.contains(where: { $0.groupID != nil }) {
      Button("Remove from Group", systemImage: "folder.badge.minus") { library.move(paths, into: nil, before: nil, context: context) }
    }
    Divider()
    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url)) }
    if let only = targets.first, targets.count == 1 {
      Button("Open in Terminal", systemImage: "terminal") { RepositoryLibrary.openInTerminal(only.url) }
    }
    Divider()
    if targets.allSatisfy(\.isHidden) {
      Button("Unhide" + suffix, systemImage: "eye") { library.setHidden(paths, false, context: context) }
    } else {
      Button("Hide" + suffix, systemImage: "eye.slash") { library.setHidden(paths, true, context: context) }
    }
    Button("Remove\(suffix) from List", systemImage: "minus.circle") {
      if let selection, paths.contains(selection) { self.selection = nil }
      selected.subtract(paths)
      library.remove(targets, from: context)
    }
  }

  @ViewBuilder
  private func remoteButtons(_ paths: [String], suffix: String) -> some View {
    ForEach([RemoteAction.fetch, .pull, .push], id: \.self) { action in
      Button(action.title + suffix, systemImage: action.systemImage) { Task { await library.run(action, on: paths) } }
        .disabled(paths.allSatisfy { library.remoteActivity[$0] != nil })
    }
  }

  // MARK: Dropping

  private func setTarget(_ id: String, _ isTargeted: Bool) {
    if isTargeted {
      dropTarget = id
    } else if dropTarget == id {
      dropTarget = nil
    }
  }

  /// Moves dropped repositories into `groupID` before `before`, moves a dropped group before the
  /// top-level item `groupBefore`, and adds dropped folders.
  private func drop(
    _ urls: [URL], into groupID: UUID?, before: String?, groupBefore: String? = nil,
    layout: SidebarLayout
  ) -> Bool {
    dropTarget = nil
    let result = Self.sort(urls, known: Set(repositories.map(\.path)))
    for id in result.groups {
      library.moveGroup(id, before: groupBefore ?? before, context: context)
    }
    if !result.repositories.isEmpty {
      let paths = expand(result.repositories, layout: layout)
      withAnimation(.kit) { library.move(paths, into: groupID, before: before, context: context) }
    }
    if !result.folders.isEmpty {
      Task { await library.importFolders(result.folders, into: context) }
    }
    return true
  }

  /// A drag of one selected row carries the whole selection.
  private func expand(_ paths: [String], layout: SidebarLayout) -> [String] {
    guard paths.count == 1, let path = paths.first else { return paths }
    return targets(for: path, layout: layout)
  }

  /// Splits dropped URLs into groups, repositories in the list, and folders to import.
  static func sort(_ urls: [URL], known: Set<String>)
    -> (groups: [UUID], repositories: [String], folders: [URL])
  {
    var result: (groups: [UUID], repositories: [String], folders: [URL]) = ([], [], [])
    for url in urls {
      if let id = SidebarItem.groupID(fromDragURL: url) {
        result.groups.append(id)
      } else if url.isFileURL, known.contains(url.standardizedFileURL.path) {
        result.repositories.append(url.standardizedFileURL.path)
      } else if url.isFileURL {
        result.folders.append(url)
      }
    }
    return result
  }
}

/// Where a dragged item will land.
private struct InsertionLine: View {
  let isShown: Bool

  var body: some View {
    if isShown {
      Capsule()
        .fill(.kitAccent)
        .frame(height: 2)
        .padding(.horizontal, 6)
        .offset(y: -1.5)
        .allowsHitTesting(false)
    }
  }
}

private struct DragPreview: View {
  let title: String
  let count: Int?

  var body: some View {
    HStack(spacing: 8) {
      Avatar(name: title, kind: .thing, size: 18)
      Text(title).fontWeight(.medium)
      if let count { Count(count, .attention) }
    }
    .padding(.horizontal, 10)
    .frame(height: 32)
    .kitSurface(.raised)
  }
}

/// A group, laid out like a repository row: the kit's disclosure, a folder tile, the name over its
/// note, and its repositories' summed state. Click collapses it.
private struct GroupHeader: View {
  let group: SavedGroup
  let summary: RepositorySummary
  let isBusy: Bool
  let isTargeted: Bool
  let help: String
  let toggle: () -> Void

  var body: some View {
    SidebarRow(group.name, subtitle: group.note.isEmpty ? nil : group.note) {
      Avatar(
        name: group.name, kind: .thing, systemImage: group.isCollapsed ? "folder" : "folder.fill",
        hue: StableHue.pick(group.name), status: isBusy ? .working : .idle, size: 18)
    } trailing: {
      StatusMarks(summary: summary)
    }
    .disclosure(isExpanded: .init(get: { !group.isCollapsed }, set: { if $0 == group.isCollapsed { toggle() } }))
    .action(toggle)
    .kitDropTarget(isTargeted)
    .animation(.kit, value: group.isCollapsed)
    .help(help)
    .accessibilityLabel("\(group.name), \(StatusMarks.description(summary))")
    .accessibilityHint(group.isCollapsed ? "Expands the group" : "Collapses the group")
  }
}

/// A repository: its letter tile, name and state. The open one is the kit's current row; others
/// selected with it are tinted.
struct RepositoryRow: View {
  let repository: SavedRepository
  let summary: RepositorySummary?
  let isCurrent: Bool
  var isSelected = false
  var activity: RemoteAction?
  /// How the last fetch, pull or push from the sidebar ended: the row plays its effect.
  var outcome: RemoteOutcome?
  /// What a click does: open it, or (⌘, ⇧) select it with others.
  let action: () -> Void

  var body: some View {
    SidebarRow(repository.name) {
      Avatar(name: repository.name, kind: .thing, status: activity == nil ? .idle : .working, size: 18)
    } trailing: {
      if let activity {
        Text("\(activity.title)ing…")
      } else if !repository.exists {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(Hue.orange.fill)
          .help("Missing")
      } else if let summary {
        StatusMarks(summary: summary)
      }
    }
    .isCurrent(isCurrent && !isSelected)
    .action(action)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous).fill(Hue.accent.soft())
      }
    }
    .animation(.kit, value: isCurrent)
    .animation(.kit, value: isSelected)
    .effect(outcome?.effect ?? .pop, on: outcome?.count)
    .help("\(repository.path)\n\(summary.map(StatusMarks.description) ?? "")")
    .accessibilityAddTraits(isCurrent || isSelected ? .isSelected : [])
  }
}
