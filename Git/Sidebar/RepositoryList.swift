import ComponentKit
import GitKit
import SwiftData
import SwiftUI
import VaultKit

/// The Repositories section: groups, which nest, and repositories in the order they were dragged
/// into, each with its state at a glance; a group's header sums up the repositories in it. The
/// groups are the vault's project tree, so the other v57 apps and Macs share them.
///
/// Click opens a repository; ⌘-click and ⇧-click select several for the context menu (Fetch,
/// Pull, Push, Hide, Move to Group) and for dragging. The kit's outline does the dragging: rows
/// slide aside, a row held over a group's middle goes into it (a closed one opens), and a row
/// dragged out of the app is its folder. Collapsed, the section keeps the open repository visible
/// and shows an icon for each other repository that needs attention.
struct RepositoryList: View {
  @Environment(RepositoryLibrary.self) private var library
  @Environment(\.modelContext) private var context
  @Query private var repositories: [SavedRepository]
  @Binding var selection: String?
  @Binding var selected: Set<String>
  let filter: String
  @State private var anchor: String?
  @State private var renaming: VaultProjectGroup?
  @State private var newName = ""
  @AppStorage("RepositoriesCollapsed") private var storedCollapsed = false
  /// The section's own state, saved to `storedCollapsed`: a defaults write drops the toggle's animation.
  @State private var isCollapsed = UserDefaults.standard.bool(forKey: "RepositoriesCollapsed")
  @AppStorage("ShowsHiddenRepositories") private var showsHidden = false

  private var layout: SidebarLayout { SidebarLayout(repositories: repositories, vault: library.vault) }

  /// An item in the outline: a group's header with what it shows, or a repository (no children).
  private struct Node: Identifiable {
    let item: SidebarItem
    var children: [Node]?
    var id: String { item.id }
  }

  /// What the list shows: the shown repositories, and the groups holding one. A group whose
  /// name matches the filter shows all it holds.
  private func nodes(_ layout: SidebarLayout) -> [Node] {
    func nodes(in groupID: String?, groupMatches: Bool) -> [Node] {
      layout.children(of: groupID).compactMap { item -> Node? in
        switch item {
        case .repository(let repository):
          let shown =
            (showsHidden || !repository.isHidden || repository.path == selection)
            && (groupMatches || filter.isEmpty || repository.name.localizedCaseInsensitiveContains(filter))
          return shown ? Node(item: item) : nil
        case .group(let group):
          let matches = groupMatches || (!filter.isEmpty && group.name.localizedCaseInsensitiveContains(filter))
          let inner = nodes(in: group.id, groupMatches: matches)
          return inner.isEmpty ? nil : Node(item: item, children: inner)
        }
      }
    }
    return nodes(in: nil, groupMatches: false)
  }

  /// The open groups' ids: those not collapsed, and every one while filtering. Opening and closing
  /// is saved only without a filter.
  private func expanded(_ nodes: [Node]) -> Binding<Set<String>> {
    func groups(_ nodes: [Node]) -> [VaultProjectGroup] {
      nodes.flatMap { node -> [VaultProjectGroup] in
        guard case .group(let group) = node.item else { return [] }
        return [group] + groups(node.children ?? [])
      }
    }
    let all = groups(nodes)
    return Binding(
      get: {
        Set(all.filter { !filter.isEmpty || !library.collapsedGroups.contains($0.id) }.map(SidebarItem.id(of:)))
      },
      set: { open in
        guard filter.isEmpty else { return }
        for group in all {
          if open.contains(SidebarItem.id(of: group)) {
            library.collapsedGroups.remove(group.id)
          } else {
            library.collapsedGroups.insert(group.id)
          }
        }
      })
  }

  /// The items on screen, top to bottom: the open groups' contents follow them.
  private func visible(_ nodes: [Node]) -> [SidebarItem] {
    nodes.flatMap { node -> [SidebarItem] in
      guard case .group(let group) = node.item else { return [node.item] }
      let isOpen = !library.collapsedGroups.contains(group.id) || !filter.isEmpty
      return [node.item] + (isOpen ? visible(node.children ?? []) : [])
    }
  }

  /// Repository paths in screen order, for ⇧-click ranges and the context menu.
  private func order(_ layout: SidebarLayout) -> [String] {
    visible(nodes(layout)).compactMap { item in
      if case .repository(let repository) = item { repository.path } else { nil }
    }
  }

  var body: some View {
    let layout = layout
    let nodes = nodes(layout)
    let hiddenCount = repositories.count { $0.isHidden }
    KitSection(
      "Repositories", meta: meta, systemImage: "folder", hue: .indigo,
      status: library.isImporting ? .working : .idle,
      isExpanded: .init(get: { !isCollapsed }, set: { isCollapsed = !$0 })
    ) {
      ReorderableOutline(
        nodes, children: \.children, expanded: expanded(nodes),
        move: { id, parent, index in move([id], into: parent, at: index, nodes: nodes) }
      ) { node in
        switch node.item {
        case .repository(let repository): repositoryRow(repository, layout: layout)
        case .group(let group): groupHeader(group, layout: layout)
        }
      }
      .dragsTogether(selected.count > 1 ? selected : []) { ids, parent, index in
        move(ids, into: parent, at: index, nodes: nodes)
      }
      .exportsURL { node in
        if case .repository(let repository) = node.item { repository.url } else { nil }
      }
      .dropTitle(root: "Repositories") { $0.item.name }
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
    .animation(.kit, value: visible(nodes).map(\.id))
    .onChange(of: isCollapsed) { storedCollapsed = isCollapsed }
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
    return GroupHeader(
      group: group, isCollapsed: library.collapsedGroups.contains(group.id) && filter.isEmpty,
      summary: RepositorySummary(combining: summaries),
      isBusy: members.contains { library.remoteActivity[$0.path] != nil },
      help: groupHelp(group, members: visible, layout: layout)
    ) {
      withAnimation(.kit) { library.toggleCollapsed(group) }
    }
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
    remoteButtons(paths, suffix: " All", pushOnlyAhead: true)
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
      Button("Show in \(KitDesktop.fileManagerName)", systemImage: "folder") {
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
      repository: repository, icon: layout.icon(of: repository.path), summary: library.summaries[repository.path],
      isCurrent: repository.path == selection, isSelected: isMulti,
      activity: library.remoteActivity[repository.path], outcome: library.remoteOutcomes[repository.path]
    ) {
      click(repository.path, layout: layout)
    }
    .opacity(repository.isHidden ? 0.5 : 1)
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
    let flags = KitDesktop.modifierKeys
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
    Button("Show in \(KitDesktop.fileManagerName)", systemImage: "folder") { KitDesktop.reveal(targets.map(\.url)) }
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

  /// Fetch, Pull and Push for `paths`; with `pushOnlyAhead`, Push leaves out the repositories
  /// with no commits for their upstream (a group's Push All).
  @ViewBuilder
  private func remoteButtons(_ paths: [String], suffix: String, pushOnlyAhead: Bool = false) -> some View {
    ForEach([RemoteAction.fetch, .pull, .push], id: \.self) { action in
      let targets = action == .push && pushOnlyAhead ? paths.filter(hasCommitsToPush) : paths
      Button(action.title + suffix, systemImage: action.systemImage) { Task { await library.run(action, on: targets) } }
        .disabled(targets.allSatisfy { library.remoteActivity[$0] != nil })
    }
  }

  private func hasCommitsToPush(_ path: String) -> Bool {
    guard let summary = library.summaries[path] else { return false }
    return summary.hasUpstream && summary.ahead > 0
  }

  // MARK: Moving

  /// Moves the dragged items (sidebar ids, top to bottom) into `parent` (a group's sidebar id, nil:
  /// the top level) at `index` among the items it shows, counted before the move. They go before
  /// the item that is there, so repositories the list hides keep their places.
  private func move(_ ids: [String], into parent: String?, at index: Int, nodes: [Node]) {
    func children(of id: String, in nodes: [Node]) -> [Node]? {
      for node in nodes {
        if node.id == id { return node.children }
        if let found = children(of: id, in: node.children ?? []) { return found }
      }
      return nil
    }
    let siblings = parent.map { children(of: $0, in: nodes) ?? [] } ?? nodes
    let before = siblings.dropFirst(index).first { !ids.contains($0.id) }?.id
    let groupID = parent.flatMap { layout.vaultID(of: $0) }
    for id in ids {
      if let group = layout.vaultID(of: id), id.hasPrefix("group:") {
        library.moveGroup(group, into: groupID, before: before, context: context)
      } else {
        library.move([id], into: groupID, before: before, context: context)
      }
    }
  }

  /// Splits dropped URLs into repositories in the list and folders to import.
  static func sort(_ urls: [URL], known: Set<String>) -> (repositories: [String], folders: [URL]) {
    var result: (repositories: [String], folders: [URL]) = ([], [])
    for url in urls where url.isFileURL {
      if known.contains(url.standardizedFileURL.path) {
        result.repositories.append(url.standardizedFileURL.path)
      } else {
        result.folders.append(url)
      }
    }
    return result
  }
}

/// A group, laid out like a repository row: the kit's disclosure, a folder tile, the name over its
/// note, and the summed state of the repositories in it. Click collapses it.
private struct GroupHeader: View {
  let group: VaultProjectGroup
  let isCollapsed: Bool
  let summary: RepositorySummary
  let isBusy: Bool
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
    .animation(.kit, value: isCollapsed)
    .help(help)
    .accessibilityLabel("\(group.name), \(StatusMarks.description(summary))")
    .accessibilityHint(isCollapsed ? "Expands the group" : "Collapses the group")
  }
}

/// A repository: its project's icon (or letter tile), name and state. The open one is the kit's current row; others
/// selected with it are tinted.
struct RepositoryRow: View {
  let repository: SavedRepository
  /// The vault's PNG of the project's app icon.
  var icon: Data?
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
      let status: WorkStatus = activity == nil ? .idle : .working
      if let image = icon.flatMap(Image.init(data:)) {
        Avatar(name: repository.name, image: image, kind: .thing, status: status, size: 18)
      } else {
        Avatar(name: repository.name, kind: .thing, status: status, size: 18)
      }
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
