import ComponentKit
import GitKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VaultKit

/// The Repositories section: groups, which nest, and repositories in the order they were dragged
/// into, each with its state at a glance; a group's header sums up the repositories in it. The
/// groups are the vault's project tree, so the other v57 apps and Macs share them.
///
/// Click opens a repository; ⌘-click and ⇧-click select several for the context menu (Fetch,
/// Pull, Push, Hide, Move to Group) and for dragging. Dropping on a group's header moves into it,
/// on its top edge before it. Collapsed, the section keeps the open repository visible and shows an
/// icon for each other repository that needs attention.
struct RepositoryList: View {
  @Environment(RepositoryLibrary.self) private var library
  @Environment(\.modelContext) private var context
  @Query private var repositories: [SavedRepository]
  @Binding var selection: String?
  @Binding var selected: Set<String>
  let filter: String
  @State private var anchor: String?
  /// The row a drag is over: its id for the insertion line above it, `in:<id>` for into a group.
  @State private var dropTarget: String?
  @State private var renaming: VaultProjectGroup?
  @State private var newName = ""
  @AppStorage("RepositoriesCollapsed") private var isCollapsed = false
  @AppStorage("ShowsHiddenRepositories") private var showsHidden = false

  private var layout: SidebarLayout { SidebarLayout(repositories: repositories, vault: library.vault) }

  /// A row on screen: a group's header or a repository, and how many groups it is in.
  private struct Row: Identifiable {
    let item: SidebarItem
    let depth: Int
    var id: String { item.id }
  }

  /// What is on screen, top to bottom: the shown repositories, and the groups holding one with
  /// their contents when open. Filtering opens every group; a group whose name matches shows all
  /// it holds.
  private func visibleRows(_ layout: SidebarLayout) -> [Row] {
    func rows(in groupID: String?, depth: Int, groupMatches: Bool) -> [Row] {
      layout.children(of: groupID).flatMap { item -> [Row] in
        switch item {
        case .repository(let repository):
          let shown =
            (showsHidden || !repository.isHidden || repository.path == selection)
            && (groupMatches || filter.isEmpty || repository.name.localizedCaseInsensitiveContains(filter))
          return shown ? [Row(item: item, depth: depth)] : []
        case .group(let group):
          let matches = groupMatches || (!filter.isEmpty && group.name.localizedCaseInsensitiveContains(filter))
          let inner = rows(in: group.id, depth: depth + 1, groupMatches: matches)
          guard !inner.isEmpty else { return [] }
          let isOpen = !library.collapsedGroups.contains(group.id) || !filter.isEmpty
          return [Row(item: item, depth: depth)] + (isOpen ? inner : [])
        }
      }
    }
    return rows(in: nil, depth: 0, groupMatches: false)
  }

  /// Repository paths in screen order, for ⇧-click ranges and for dragging several.
  private func order(_ layout: SidebarLayout) -> [String] {
    visibleRows(layout).compactMap { row in
      if case .repository(let repository) = row.item { repository.path } else { nil }
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
      ForEach(rows) { row in
        switch row.item {
        case .repository(let repository):
          repositoryRow(repository, layout: layout)
            .kitRowIndent(row.depth)
        case .group(let group):
          groupHeader(group, layout: layout)
            .kitRowIndent(row.depth)
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
    .help(attentionHelp(layout))
    .animation(.kit, value: rows.map(\.id))
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
        if let group = renaming, !name.isEmpty { library.rename(group, to: name) }
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
  private func attentionHelp(_ layout: SidebarLayout) -> String {
    guard isCollapsed else { return "" }
    let lines = layout.repositories().filter { $0.path != selection && !$0.isHidden }
      .compactMap { repository in
        library.summaries[repository.path].flatMap {
          $0.needsAttention ? "\(repository.name): \(StatusMarks.description($0))" : nil
        }
      }
    return lines.isEmpty ? "All other repositories are up to date" : lines.joined(separator: "\n")
  }

  // MARK: Groups

  private func groupHeader(_ group: VaultProjectGroup, layout: SidebarLayout) -> some View {
    let members = layout.repositories(in: group.id)
    let visible = members.filter { !$0.isHidden }
    let summaries = visible.compactMap { library.summaries[$0.path] }
    let id = SidebarItem.id(of: group)
    return GroupHeader(
      group: group, isCollapsed: library.collapsedGroups.contains(group.id),
      summary: RepositorySummary(combining: summaries),
      isBusy: members.contains { library.remoteActivity[$0.path] != nil },
      isTargeted: dropTarget == "in:" + id,
      help: groupHelp(group, members: visible, layout: layout)
    ) {
      withAnimation(.kit) { library.toggleCollapsed(group) }
    }
    .overlay(alignment: .top) { InsertionLine(isShown: dropTarget == id) }
    .draggable(SidebarItem.dragURL(for: group)) {
      DragPreview(title: group.name, count: nil)
    }
    .onDrop(
      of: [.url],
      delegate: GroupDropDelegate(id: id, target: $dropTarget) { urls, into in
        if into {
          _ = drop(urls, into: group.id, before: nil, layout: layout)
        } else {
          _ = drop(urls, into: layout.tree.parent(of: group.id), before: id, layout: layout)
        }
      }
    )
    .kitContextMenu { groupMenu(group, members: members, layout: layout) }
    .transition(.row)
  }

  private func groupHelp(_ group: VaultProjectGroup, members: [SavedRepository], layout: SidebarLayout) -> String {
    let lines = members.compactMap { repository in
      library.summaries[repository.path].flatMap {
        $0.needsAttention ? "\(repository.name): \(StatusMarks.description($0))" : nil
      }
    }
    let title = group.paths[library.vault.deviceID] ?? layout.title(of: group)
    let count = members.count == 1 ? "1 repository" : "\(members.count) repositories"
    return ([title, count] + lines).joined(separator: "\n")
  }

  @ViewBuilder
  private func groupMenu(_ group: VaultProjectGroup, members: [SavedRepository], layout: SidebarLayout)
    -> some View
  {
    let paths = members.map(\.path)
    let parent = layout.tree.parent(of: group.id)
    // Groups it can move into: not itself, not one inside it, not the one it is in.
    let destinations = layout.tree.groups.filter { !layout.tree.isWithin($0.id, group.id) && $0.id != parent }
    remoteButtons(paths, suffix: " All")
    Divider()
    Button("Rename…", systemImage: "pencil") {
      newName = group.name
      renaming = group
    }
    Button("Ungroup", systemImage: "folder.badge.minus") { withAnimation(.kit) { library.ungroup(group) } }
    if !destinations.isEmpty {
      KitSubmenu("Move to Group", systemImage: "folder") {
        ForEach(destinations) { destination in
          Button(groupTitle(destination, layout: layout)) {
            withAnimation(.kit) { library.moveGroup(group.id, into: destination.id, before: nil, context: context) }
          }
        }
      }
    }
    if parent != nil {
      Button("Move Out of Group", systemImage: "arrow.up.left") {
        withAnimation(.kit) { library.moveOut([SidebarItem.id(of: group)], context: context) }
      }
    }
    Divider()
    if let folder = group.paths[library.vault.deviceID] {
      Button("Show in Finder", systemImage: "folder") {
        RepositoryLibrary.reveal(URL(fileURLWithPath: folder, isDirectory: true))
      }
      Divider()
    }
    if members.allSatisfy(\.isHidden) {
      Button("Unhide Group", systemImage: "eye") { library.setHidden(paths, false, context: context) }
    } else {
      Button("Hide Group", systemImage: "eye.slash") { library.setHidden(paths, true, context: context) }
    }
  }

  /// "v57 › Agentus (Developer)": a group with the groups it is in, and its note.
  private func groupTitle(_ group: VaultProjectGroup, layout: SidebarLayout) -> String {
    let title = layout.title(of: group)
    guard let note = group.note, !note.isEmpty else { return title }
    return "\(title) (\(note))"
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
      drop(urls, into: layout.groupID(of: repository.path), before: repository.path, layout: layout)
    } isTargeted: { setTarget(repository.path, $0) }
    .kitContextMenu { repositoryMenu(targets(for: repository.path, layout: layout), layout: layout) }
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
  private func repositoryMenu(_ paths: [String], layout: SidebarLayout) -> some View {
    let targets = paths.compactMap { path in repositories.first { $0.path == path } }
    let suffix = targets.count > 1 ? " \(targets.count) Repositories" : ""
    let groups = layout.tree.groups
    remoteButtons(paths, suffix: suffix)
    Divider()
    KitSubmenu("Move to Group", systemImage: "folder") {
      ForEach(groups) { group in
        Button(groupTitle(group, layout: layout)) {
          withAnimation(.kit) { library.move(paths, into: group.id, before: nil, context: context) }
        }
        .disabled(paths.allSatisfy { layout.groupID(of: $0) == group.id })
      }
      if !groups.isEmpty { Divider() }
      Button("New Group…", systemImage: "folder.badge.plus") {
        if let group = withAnimation(.kit, { library.newGroup(from: paths, context: context) }) {
          newName = group.name
          renaming = group
        }
      }
    }
    if paths.contains(where: { layout.groupID(of: $0) != nil }) {
      Button("Remove from Group", systemImage: "folder.badge.minus") {
        withAnimation(.kit) { library.moveOut(paths, context: context) }
      }
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

  /// Moves dropped repositories and groups into `groupID` (nil: the top level) before the item
  /// `before` there, or at the end, and adds dropped folders.
  private func drop(_ urls: [URL], into groupID: String?, before: String?, layout: SidebarLayout) -> Bool {
    dropTarget = nil
    let result = Self.sort(urls, known: Set(repositories.map(\.path)))
    withAnimation(.kit) {
      for id in result.groups {
        library.moveGroup(id, into: groupID, before: before, context: context)
      }
      if !result.repositories.isEmpty {
        library.move(expand(result.repositories, layout: layout), into: groupID, before: before, context: context)
      }
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
    -> (groups: [String], repositories: [String], folders: [URL])
  {
    var result: (groups: [String], repositories: [String], folders: [URL]) = ([], [], [])
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

/// Drops on a group's header: on its top edge before the group (the insertion line shows), anywhere
/// else into it (the header lights up).
private struct GroupDropDelegate: DropDelegate {
  let id: String
  @Binding var target: String?
  let perform: (_ urls: [URL], _ into: Bool) -> Void

  /// How far down the header "before" reaches.
  private static let edge: CGFloat = 7

  private func isInto(_ info: DropInfo) -> Bool { info.location.y >= Self.edge }

  func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.url]) }

  func dropEntered(info: DropInfo) { target = isInto(info) ? "in:" + id : id }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    target = isInto(info) ? "in:" + id : id
    return DropProposal(operation: .copy)
  }

  func dropExited(info: DropInfo) {
    if target == id || target == "in:" + id { target = nil }
  }

  func performDrop(info: DropInfo) -> Bool {
    let into = isInto(info)
    let providers = info.itemProviders(for: [.url])
    target = nil
    Task {
      var urls: [URL] = []
      for provider in providers {
        if let url = await provider.droppedURL() { urls.append(url) }
      }
      perform(urls, into)
    }
    return true
  }
}

extension NSItemProvider {
  /// The URL a drop carries: a file, or a dragged group's `x-git-group:` URL.
  fileprivate func droppedURL() async -> URL? {
    await withCheckedContinuation { continuation in
      _ = loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
    }
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
/// note, and the summed state of the repositories in it. Click collapses it.
private struct GroupHeader: View {
  let group: VaultProjectGroup
  let isCollapsed: Bool
  let summary: RepositorySummary
  let isBusy: Bool
  let isTargeted: Bool
  let help: String
  let toggle: () -> Void

  var body: some View {
    SidebarRow(group.name, subtitle: group.note?.isEmpty == false ? group.note : nil) {
      Avatar(
        name: group.name, kind: .thing, systemImage: isCollapsed ? "folder" : "folder.fill",
        hue: StableHue.pick(group.name), status: isBusy ? .working : .idle, size: 18)
    } trailing: {
      StatusMarks(summary: summary)
    }
    .disclosure(isExpanded: .init(get: { !isCollapsed }, set: { if $0 == isCollapsed { toggle() } }))
    .action(toggle)
    .kitDropTarget(isTargeted)
    .animation(.kit, value: isCollapsed)
    .help(help)
    .accessibilityLabel("\(group.name), \(StatusMarks.description(summary))")
    .accessibilityHint(isCollapsed ? "Expands the group" : "Collapses the group")
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
