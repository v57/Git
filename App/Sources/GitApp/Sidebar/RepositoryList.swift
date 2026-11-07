import ComponentKit
import GitKit
import GitRemote
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VaultKit
import VaultUI

/// The Repositories section: groups, which nest, and repositories in the order they were dragged
/// into, each with its state at a glance; a group's header sums up the repositories in it. The
/// groups are the vault's project tree, so the other v57 apps and Macs share them.
///
/// Click opens a repository; ⌘-click and ⇧-click select several for the context menu (Fetch,
/// Pull, Push, Hide, Move to Group, Remove from List) and for dragging; a group's menu removes its repositories, the
/// section header's all of them. The kit's outline does the dragging: rows
/// slide aside, a row held over a group's middle goes into it (a closed one opens), and a row
/// dragged out of the app is its folder. Collapsed, the section keeps the open repository visible
/// and shows an icon for each other repository that needs attention.
///
/// The header's context menu orders a long list (by name, recent changes, last commit or last push), hides
/// repositories unused for a week or without changes behind a Show More row, groups by folder or not, and picks where
/// the open repository's Workspace goes (`VaultProjectsLayout`). Without folders, or sorted by date, the list doesn't
/// reorder by dragging (a drag still moves a repository into a folder).
struct RepositoryList: View {
  @Environment(RepositoryLibrary.self) private var library
  @Environment(\.modelContext) private var context
  @Query private var savedRepositories: [SavedRepository]
  /// The window's account's repositories.
  private var repositories: [SavedRepository] { savedRepositories.filter(library.owns) }
  @Binding var selection: String?
  @Binding var selected: Set<String>
  /// The repository on screen, whose Workspace goes under its row in `.inline`.
  let shown: String?
  let filter: String
  @State private var anchor: String?
  /// The group whose name is a field in its row.
  @State private var renaming: VaultProjectGroup.ID?
  @KitStorage("RepositoriesCollapsed") private var storedCollapsed = false
  /// The section's own state, saved to `storedCollapsed`: a defaults write drops the toggle's animation.
  @State private var isCollapsed = UserDefaults.standard.bool(forKey: "RepositoriesCollapsed")
  @KitStorage("ShowsHiddenRepositories") private var showsHidden = false
  @KitStorage("RepositoriesSort") private var sort = RepositorySort.name
  @KitStorage("RepositoriesHideUnused") private var hidesUnused = false
  @KitStorage("RepositoriesOnlyWithChanges") private var onlyWithChanges = false
  @KitStorage("RepositoriesGroupByFolder") private var groupsByFolder = true
  @KitStorage(VaultProjectsLayout.gitKey) private var projectsLayout = VaultProjectsLayout.separate
  /// Show More: the repositories the filters hide, until the list is filtered again.
  @State private var showsMore = false
  @State private var confirmsRemoveAll = false
  @State private var confirmsRemoveProjects = false
  /// What the rows do, filled as the list updates (`RepositoryRowActions`).
  @State private var rowActions = RepositoryRowActions()

  private var layout: SidebarLayout { SidebarLayout(repositories: repositories, vault: library.vault) }

  /// An item in the outline: a group's header with what it shows, or a repository (no children).
  private struct Node: Identifiable {
    let item: SidebarItem
    var children: [Node]?
    var id: String { item.id }
  }

  /// What the list shows: the shown repositories, and the groups holding one. A group whose
  /// name matches the filter shows all it holds. Sorted by a date, each group's items go newest first (a group by
  /// its newest repository); without folders the repositories are one list.
  private func nodes(_ layout: SidebarLayout) -> [Node] {
    func nodes(in groupID: String?, groupMatches: Bool) -> [Node] {
      let nodes = layout.children(of: groupID).compactMap { item -> Node? in
        switch item {
        case .repository(let repository):
          let shown =
            isListed(repository) && passesOptions(repository)
            && (groupMatches || filter.isEmpty || repository.name.localizedCaseInsensitiveContains(filter))
          return shown ? Node(item: item) : nil
        case .group(let group):
          let matches = groupMatches || (!filter.isEmpty && group.name.localizedCaseInsensitiveContains(filter))
          let inner = nodes(in: group.id, groupMatches: matches)
          return inner.isEmpty ? nil : Node(item: item, children: inner)
        }
      }
      return sort == .name ? nodes : RepositoryOrder.sorted(nodes, by: sort, name: \.item.name, date: newest)
    }
    guard groupsByFolder else {
      let repositories = layout.repositories().filter { repository in
        isListed(repository) && passesOptions(repository)
          && (filter.isEmpty || repository.name.localizedCaseInsensitiveContains(filter))
      }
      return RepositoryOrder.sorted(repositories, by: sort, name: \.name) { sort.date(library.activities[$0.path]) }
        .map { Node(item: .repository($0)) }
    }
    return nodes(in: nil, groupMatches: false)
  }

  /// A node's date for the sort: a repository's own, a group's newest repository's.
  private func newest(_ node: Node) -> Date? {
    switch node.item {
    case .repository(let repository): sort.date(library.activities[repository.path])
    case .group: (node.children ?? []).compactMap(newest).max()
    }
  }

  /// Not hidden (or Show Hidden is on), or the open one.
  private func isListed(_ repository: SavedRepository) -> Bool {
    showsHidden || !repository.isHidden || repository.path == selection
  }

  /// Passes the menu's filters (Hide Unused for a Week, Only With Changes); the open repository always does, and
  /// every one does after Show More or while searching.
  private func passesOptions(_ repository: SavedRepository, showingMore: Bool? = nil) -> Bool {
    if showingMore ?? showsMore || !filter.isEmpty || repository.path == selection { return true }
    if onlyWithChanges, library.summaries[repository.path]?.needsAttention != true { return false }
    if hidesUnused, RepositoryOrder.isUnused(repository, activity: library.activities[repository.path]) {
      return false
    }
    return true
  }

  /// The listed repositories the filters hide, for the Show More row.
  private func filteredOut(_ layout: SidebarLayout) -> Int {
    guard filter.isEmpty, hidesUnused || onlyWithChanges else { return 0 }
    return layout.repositories().count { isListed($0) && !passesOptions($0, showingMore: false) }
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
    order(visible(nodes(layout)))
  }

  private func order(_ visible: [SidebarItem]) -> [String] {
    visible.compactMap { item in
      if case .repository(let repository) = item { repository.path } else { nil }
    }
  }

  var body: some View {
    let layout = layout
    let nodes = nodes(layout)
    let visibleIDs = visible(nodes).map(\.id)
    let hiddenCount = repositories.count { $0.isHidden }
    let more = filteredOut(layout)
    let actions = rowActions.configured(
      click: { click($0, layout: layout) },
      menu: { AnyView(repositoryMenu(targets(for: $0, layout: layout), layout: layout)) },
      groupMenu: { group, members in AnyView(groupMenu(group, members: members, layout: layout)) },
      toggle: { group in withAnimation(.kit) { library.toggleCollapsed(group) } },
      rename: { group, name in library.rename(group, to: name) },
      endRename: { renaming = nil })
    KitSection(
      "Repositories", meta: meta(layout, more: more), systemImage: "folder", hue: .indigo,
      status: library.isImporting ? .working : .idle,
      // Folded, a search still shows what it finds.
      isExpanded: .init(
        get: { !isCollapsed || (projectsLayout == .folding && !filter.isEmpty) }, set: { isCollapsed = !$0 })
    ) {
      if groupsByFolder {
        ReorderableOutline(
          nodes, children: \.children, expanded: expanded(nodes),
          move: { id, parent, index in move([id], into: parent, at: index, nodes: nodes) }
        ) { node in
          switch node.item {
          case .repository(let repository): repositoryRow(repository, layout: layout, actions: actions)
          case .group(let group): groupHeader(group, layout: layout, actions: actions)
          }
        }
        .dragsTogether(selected.count > 1 ? selected : []) { ids, parent, index in
          move(ids, into: parent, at: index, nodes: nodes)
        }
        .exportsURL { node in
          if case .repository(let repository) = node.item { repository.url } else { nil }
        }
        .dropTitle(root: "Repositories") { $0.item.name }
        // Folders from Finder go where the rows make room for them, as a dragged row would (into a group held over).
        .acceptsDrops(of: [.fileURL]) { providers, parent, index in
          KitDroppedFiles.load(providers) { drop($0, into: parent, at: index, nodes: nodes) }
        }
      } else {
        // One list in the sort's order: dragging would move repositories out of their folders.
        ForEach(nodes) { node in
          if case .repository(let repository) = node.item {
            repositoryRow(repository, layout: layout, actions: actions)
          }
        }
      }
      if more > 0 || showsMore {
        SidebarShowMoreRow(
          count: more, isShowing: $showsMore, reason: moreReason,
          help: "Show \(more) repositories \(moreReason)",
          hideHelp: "Hide the repositories the filters leave out")
      }
      if hiddenCount > 0 && filter.isEmpty {
        Button(showsHidden ? "Hide Hidden Repositories" : "Show \(hiddenCount) Hidden") {
          withKitAnimation { showsHidden.toggle() }
        }
        .buttonStyle(.kitPlain)
        .controlSize(.small)
        .padding(.leading, 4)
      }
    } accessory: {
      AddRepositoryButton()
    }
    .headerMenu {
      optionsMenu
      Divider()
      Button("Remove All Repositories from List", systemImage: "minus.circle") { confirmsRemoveAll = true }
        .disabled(repositories.isEmpty)
      Button("Remove All Projects…", systemImage: "trash") { confirmsRemoveProjects = true }
        .disabled(repositories.isEmpty && library.unlistedProjects(besides: repositories).isEmpty)
    }
    .help(attentionHelp(layout))
    .kitConfirmation(
      repositories.count == 1 ? "Remove 1 repository from the list?" : "Remove all \(repositories.count) repositories from the list?", isPresented: $confirmsRemoveAll,
      message: "Their folders stay on disk.", systemImage: "minus.circle",
      confirm: "Remove All"
    ) {
      selection = nil
      selected = []
      withAnimation(.kit) { library.remove(repositories, from: context) }
    }
    .kitSheet(isPresented: $confirmsRemoveProjects) {
      RemoveProjectsSheet(repositories: repositories) {
        selection = nil
        selected = []
        withAnimation(.kit) { library.removeAllProjects(repositories, from: context) }
      }
    }
    // A filter turned on again hides what Show More showed.
    .onChange(of: [hidesUnused, onlyWithChanges]) { showsMore = false }
    .animation(.kit, value: visibleIDs)
    .onChange(of: isCollapsed) { storedCollapsed = isCollapsed }
    // `.folding`: a picked repository folds the list, as does choosing it with one open; the others open it again.
    .onChange(of: selection) { _, new in
      if projectsLayout == .folding, new != nil { isCollapsed = true }
    }
    .onChange(of: projectsLayout) { _, new in isCollapsed = new == .folding && selection != nil }
    .onChange(of: selection, initial: true) { _, path in
      if let path, !selected.contains(path) || selected.count == 1 {
        selected = [path]
        anchor = path
      }
    }
  }

  // MARK: Header

  /// "5 repositories · 2 with changes", "Recent changes · 14 of 72" while sorted by a date and filtered, or what
  /// the import is doing.
  private func meta(_ layout: SidebarLayout, more: Int) -> [String] {
    if library.isImporting { return ["Looking for repositories…"] }
    let shown = repositories.filter { !$0.isHidden }
    let attention = shown.count { library.summaries[$0.path]?.needsAttention == true }
    let listed = layout.repositories().count(where: isListed)
    let count =
      more > 0 && !showsMore
      ? "\(listed - more) of \(listed)" : shown.count == 1 ? "1 repository" : "\(shown.count) repositories"
    if let order = sort.metaTitle { return [order, count] }
    return [count, attention > 0 ? "\(attention) with changes" : ""]
  }

  /// The All Repositories page, then Sort By and Show, as on the board: the sort's options, then the filters and
  /// the folders; then where the open repository's Workspace goes.
  @ViewBuilder private var optionsMenu: some View {
    Button("All Repositories", systemImage: "square.grid.2x2") {
      withKitAnimation { library.showsAllRepositories = true }
    }
    Divider()
    KitSubmenu("Sort By", value: sort.title) {
      KitMenuOptions(
        selection: Binding(
          get: { sort },
          set: { new in
            withKitAnimation {
              sort = new
              // Folders keep their own order: on by name, off by a date.
              groupsByFolder = new == .name
            }
          }),
        options: RepositorySort.allCases.map { ($0.title, $0) })
    }
    .kitMenuPreview("Changes the order of this list only; a date order turns off Group by Folder. Your repositories stay as they are.")
    ProjectsLayoutMenu(asSubmenu: true)
    Divider()
    Toggle("Hide Unused for a Week", isOn: $hidesUnused.animation(.kit))
    Toggle("Only With Changes", isOn: $onlyWithChanges.animation(.kit))
    Toggle("Group by Folder", isOn: $groupsByFolder.animation(.kit))
  }

  /// What Show More brings back.
  private var moreReason: String {
    switch (hidesUnused, onlyWithChanges) {
    case (true, true): "unused or unchanged"
    case (true, false): "unused for a week"
    default: "without changes"
    }
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

  private func groupHeader(_ group: VaultProjectGroup, layout: SidebarLayout, actions: RepositoryRowActions)
    -> some View
  {
    let members = layout.repositories(in: group.id)
    let visible = members.filter { !$0.isHidden }
    let summaries = visible.compactMap { library.summaries[$0.path] }
    return GroupHeader(
      group: group, isCollapsed: library.collapsedGroups.contains(group.id) && filter.isEmpty,
      summary: RepositorySummary(combining: summaries),
      isBusy: members.contains { library.remoteActivity[$0.path] != nil },
      help: groupHelp(group, members: visible, layout: layout), actions: actions
    )
    .equatable()
    .modifier(GroupExtras(group: group, members: members, isRenaming: renaming == group.id, actions: actions))
    .transition(.row)
  }

  private func groupHelp(_ group: VaultProjectGroup, members: [SavedRepository], layout: SidebarLayout) -> GroupHelp {
    let attention = members.compactMap { repository in
      library.summaries[repository.path].flatMap {
        $0.needsAttention ? GroupHelp.Line(path: repository.path, name: repository.name, summary: $0) : nil
      }
    }
    // Where it is on this Mac, else its place among the groups (nothing when that is just its name).
    let place =
      group.paths[library.vault.deviceID].map { ($0 as NSString).abbreviatingWithTildeInPath }
      ?? layout.title(of: group)
    let count = members.count == 1 ? "1 repository" : "\(members.count) repositories"
    return GroupHelp(meta: [place == group.name ? nil : place, count].compactMap { $0 }.joined(separator: " · "), attention: attention)
  }

  @ViewBuilder
  private func groupMenu(_ group: VaultProjectGroup, members: [SavedRepository], layout: SidebarLayout)
    -> some View
  {
    let paths = members.map(\.path)
    let parent = layout.tree.parent(of: group.id)
    // Groups it can move into: not itself, not one inside it, not the one it is in.
    let destinations = layout.tree.groups.filter { !layout.tree.isWithin($0.id, group.id) && $0.id != parent }
    remoteButtons(paths, suffix: " All", pushOnlyAhead: true, words: groupWords(paths))
    Divider()
    Button("Rename…", systemImage: "pencil") {
      renaming = group.id
    }
    Button("Ungroup", systemImage: "folder.badge.minus") { withAnimation(.kit) { library.ungroup(group) } }
      .kitMenuPreview("Takes the group away; its \(repositoriesText(members.count)) stay in the list. Nothing changes on disk.")
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
      let url = URL(fileURLWithPath: folder, isDirectory: true)
      KitOpenWithRow([
        .app(codeBundleID, name: "Code", opening: [url], preview: "Opens the \(group.name) folder in Code."),
        .fileManager(revealing: [url], preview: "Shows the \(group.name) folder in \(KitDesktop.fileManagerName)."),
        .terminal(at: url, preview: "Opens Terminal in the \(group.name) folder."),
      ])
      Divider()
    }
    if members.allSatisfy(\.isHidden) {
      Button("Unhide Group", systemImage: "eye") { library.setHidden(paths, false, context: context) }
    } else {
      Button("Hide Group", systemImage: "eye.slash") { library.setHidden(paths, true, context: context) }
    }
    Button("Remove Group from List", systemImage: "minus.circle") {
      if let selection, paths.contains(selection) { self.selection = nil }
      selected.subtract(paths)
      withAnimation(.kit) { library.remove(group, members: members, from: context) }
    }
    .kitMenuPreview("Takes its \(repositoriesText(members.count)) off this list. Their folders stay.")
  }

  /// "v57 › Agentus (Developer)": a group with the groups it is in, and its note.
  private func groupTitle(_ group: VaultProjectGroup, layout: SidebarLayout) -> String {
    let title = layout.title(of: group)
    guard let note = group.note, !note.isEmpty else { return title }
    return "\(title) (\(note))"
  }

  // MARK: Repositories

  private func repositoryRow(_ repository: SavedRepository, layout: SidebarLayout, actions: RepositoryRowActions)
    -> some View
  {
    let isMulti = selected.count > 1 && selected.contains(repository.path)
    return VStack(alignment: .leading, spacing: 2) {
      RepositoryRow(
        repository: repository, icon: layout.icon(of: repository.path), summary: library.summaries[repository.path],
        isCurrent: repository.path == selection, isSelected: isMulti,
        activity: library.remoteActivity[repository.path], outcome: library.remoteOutcomes[repository.path],
        actions: actions
      )
      .equatable()
      .opacity(repository.isHidden ? 0.5 : 1)
      .modifier(RepositoryRowMenu(path: repository.path, actions: actions))
      if projectsLayout == .inline, repository.path == shown, let session = library.loadedSession(for: repository.path) {
        InlineWorkspaceRows(session: session, steps: groupsByFolder ? 2 : 1)
      }
    }
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
      if library.showsAllRepositories { withKitAnimation { library.showsAllRepositories = false } }
    }
  }

  @ViewBuilder
  private func repositoryMenu(_ paths: [String], layout: SidebarLayout) -> some View {
    let targets = paths.compactMap { path in repositories.first { $0.path == path } }
    let suffix = targets.count > 1 ? " \(targets.count) Repositories" : ""
    let groups = layout.tree.groups
    let only = targets.count == 1 ? targets.first : nil
    remoteButtons(paths, suffix: suffix, words: only.flatMap(repositoryWords))
    Divider()
    openWithRow(targets)
    Divider()
    // The group they are all in, checked.
    let inGroups = Set(paths.map { layout.groupID(of: $0) })
    let current = inGroups.count == 1 ? inGroups.first ?? nil : nil
    KitSubmenu("Group", value: groups.first { $0.id == current }?.name, systemImage: "folder") {
      KitMenuOptions(
        selection: Binding(
          get: { current },
          set: { new in
            guard let new, !paths.allSatisfy({ layout.groupID(of: $0) == new }) else { return }
            withAnimation(.kit) { library.move(paths, into: new, before: nil, context: context) }
          }),
        segments: groups.map { group in
          KitSegment(
            groupTitle(group, layout: layout), value: Optional(group.id),
            isEnabled: !paths.allSatisfy { layout.groupID(of: $0) == group.id })
        })
      if !groups.isEmpty { Divider() }
      Button("New Group…", systemImage: "folder.badge.plus") {
        if let group = withAnimation(.kit, { library.newGroup(from: paths, context: context) }) {
          renaming = group.id
        }
      }
      if paths.contains(where: { layout.groupID(of: $0) != nil }) {
        Button("Remove from Group", systemImage: "folder.badge.minus") {
          withAnimation(.kit) { library.moveOut(paths, context: context) }
        }
      }
    }
    if let only {
      VaultOtherPlacesMenu(root: only.url)
    }
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
    .kitMenuPreview(
      only.map { "Takes \($0.name) off this list. Its folder stays." }
        ?? "Takes these \(repositoriesText(targets.count)) off this list. Their folders stay.")
  }

  /// Open With for repositories: Xcode (when there's a project) and Code for one, Finder for all, Terminal for one.
  @ViewBuilder
  private func openWithRow(_ targets: [SavedRepository]) -> some View {
    let only = targets.count == 1 ? targets.first : nil
    let name = only?.name ?? ""
    KitOpenWithRow([
      only.flatMap { repository in
        Self.xcodeProject(in: repository.url).flatMap {
          .app("com.apple.dt.Xcode", name: "Xcode", opening: [$0], preview: "Opens \(name) in Xcode.")
        }
      },
      only.flatMap { .app(codeBundleID, name: "Code", opening: [$0.url], preview: "Opens \(name) in Code.") },
      .fileManager(
        revealing: targets.map(\.url),
        preview: only == nil
          ? "Shows these \(repositoriesText(targets.count)) in \(KitDesktop.fileManagerName)."
          : "Shows the \(name) folder in \(KitDesktop.fileManagerName)."),
      only.flatMap { .terminal(at: $0.url, preview: "Opens Terminal in the \(name) folder.") },
    ])
  }

  /// The Xcode workspace, project or Swift package at the top of a repository, for Open in Xcode.
  private static func xcodeProject(in folder: URL) -> URL? {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    let name =
      names.first { $0.hasSuffix(".xcworkspace") } ?? names.first { $0.hasSuffix(".xcodeproj") }
      ?? names.first { $0 == "Package.swift" }
    return name.map { folder.appendingPathComponent($0) }
  }

  /// Fetch, Pull and Push for one repository: the commits to pull and push, from the sidebar's summary.
  private func repositoryWords(_ repository: SavedRepository) -> RemoteActionWords? {
    guard let summary = library.summaries[repository.path] else { return nil }
    let branch = summary.branch ?? "this branch"
    let upstream = library.loadedSession(for: repository.path)?.status?.upstream
    let remote = upstream?.split(separator: "/").first.map(String.init)
    let from = remote ?? "the remote"
    let behind = summary.behind
    let ahead = summary.ahead
    let stay = ahead == 1 ? " Your 1 commit stays." : ahead > 1 ? " Your \(ahead) commits stay." : ""
    return RemoteActionWords { action in
      switch action {
      case .fetch:
        RemoteActionWords.Row(preview: "Checks \(from) for new commits. Nothing in \(branch) changes.")
      case .pull:
        behind > 0
          ? RemoteActionWords.Row(
            hint: counted(behind, "commit"), preview: "Brings \(counted(behind, "commit")) from \(from) into \(branch).\(stay)",
            picture: BranchPicture(.pull(incoming: behind, yours: ahead, branch: branch, source: remote)))
          : RemoteActionWords.Row(preview: "Brings any new commits from \(from) into \(branch).\(stay)")
      case .push:
        RemoteActionWords.Row(
          hint: ahead > 0 ? counted(ahead, "commit") : nil,
          preview: ahead > 0 ? "Sends your \(counted(ahead, "commit")) on \(branch) to \(from)." : "Sends \(branch) to \(from).")
      }
    }
  }

  /// Fetch All, Pull All and Push All for a group: the commits to pull and push, summed.
  private func groupWords(_ paths: [String]) -> RemoteActionWords {
    let summaries = paths.compactMap { library.summaries[$0] }
    let behind = summaries.reduce(0) { $0 + $1.behind }
    let ahead = paths.filter(hasCommitsToPush).compactMap { library.summaries[$0]?.ahead }.reduce(0, +)
    let repositories = repositoriesText(paths.count)
    return RemoteActionWords { action in
      switch action {
      case .fetch:
        RemoteActionWords.Row(preview: "Checks the remotes of its \(repositories) for new commits. Nothing in them changes.")
      case .pull:
        RemoteActionWords.Row(
          hint: behind > 0 ? counted(behind, "commit") : nil,
          preview: behind > 0
            ? "Brings \(counted(behind, "commit")) into its \(repositories), each from its own remote."
            : "Brings any new commits into its \(repositories), each from its own remote.")
      case .push:
        RemoteActionWords.Row(
          hint: ahead > 0 ? counted(ahead, "commit") : nil,
          preview: ahead > 0
            ? "Sends \(counted(ahead, "commit")) to their remotes, from the repositories that have some."
            : "Sends the commits of the repositories that have some to their remotes.")
      }
    }
  }

  private func repositoriesText(_ count: Int) -> String {
    count == 1 ? "1 repository" : "\(count) repositories"
  }

  /// Fetch, Pull and Push for `paths`; with `pushOnlyAhead`, Push leaves out the repositories
  /// with no commits for their upstream (a group's Push All).
  @ViewBuilder
  private func remoteButtons(
    _ paths: [String], suffix: String, pushOnlyAhead: Bool = false, words: RemoteActionWords? = nil
  ) -> some View {
    RemoteActionButtons(
      paths: paths, pushPaths: pushOnlyAhead ? paths.filter(hasCommitsToPush) : paths, suffix: suffix, words: words)
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
    let (groupID, before) = destination(of: ids, into: parent, at: index, nodes: nodes)
    for id in ids {
      if let group = layout.vaultID(of: id), id.hasPrefix("group:") {
        library.moveGroup(group, into: groupID, before: before, context: context)
      } else {
        library.move([id], into: groupID, before: before, context: context)
      }
    }
  }

  /// The group (vault id) and the item to go before (sidebar id; `nil`: the end) for items going into `parent` at
  /// `index`, as `move` counts them.
  private func destination(of ids: [String], into parent: String?, at index: Int, nodes: [Node]) -> (
    group: String?, before: String?
  ) {
    func children(of id: String, in nodes: [Node]) -> [Node]? {
      for node in nodes {
        if node.id == id { return node.children }
        if let found = children(of: id, in: node.children ?? []) { return found }
      }
      return nil
    }
    let siblings = parent.map { children(of: $0, in: nodes) ?? [] } ?? nodes
    let before = siblings.dropFirst(index).first { !ids.contains($0.id) }?.id
    return (parent.flatMap { layout.vaultID(of: $0) }, before)
  }

  /// Files dropped on a row: repositories in the list move there, as their rows would; folders are added there.
  private func drop(_ urls: [URL], into parent: String?, at index: Int, nodes: [Node]) {
    let result = Self.sort(urls, known: Set(repositories.map(\.path)))
    if !result.repositories.isEmpty { move(result.repositories, into: parent, at: index, nodes: nodes) }
    guard !result.folders.isEmpty else { return }
    let (groupID, before) = destination(of: [], into: parent, at: index, nodes: nodes)
    Task {
      let added = await library.importFolders(result.folders, into: context, group: groupID, before: before)
      if let first = added.first { selection = first }
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
private struct GroupHeader: View, Equatable {
  let group: VaultProjectGroup
  let isCollapsed: Bool
  let summary: RepositorySummary
  let isBusy: Bool
  let help: GroupHelp
  let actions: RepositoryRowActions

  /// The actions box stays the same; the rest is what the header draws.
  nonisolated static func == (a: Self, b: Self) -> Bool {
    MainActor.assumeIsolated {
      a.group == b.group && a.isCollapsed == b.isCollapsed && a.summary == b.summary && a.isBusy == b.isBusy
        && a.help == b.help && a.actions === b.actions
    }
  }

  private func toggle() { actions.toggle(group) }

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
    .kitHelp(group.name, meta: help.meta, systemImage: "folder", hue: StableHue.pick(group.name)) {
      GroupHelpDetail(help: help)
    }
    .accessibilityLabel("\(group.name), \(StatusMarks.description(summary))")
    .accessibilityHint(isCollapsed ? "Expands the group" : "Collapses the group")
  }
}

/// Fetch, Pull and Push for a menu, on repositories here or on other devices (`RepositoryLibrary.run`).
struct RemoteActionButtons: View {
  @Environment(RepositoryLibrary.self) private var library
  let paths: [String]
  /// The ones Push goes to.
  let pushPaths: [String]
  let suffix: String
  /// The rows' ends and sentences, when the menu knows the counts.
  var words: RemoteActionWords? = nil

  var body: some View {
    ForEach([RemoteAction.fetch, .pull, .push], id: \.self) { action in
      let targets = action == .push ? pushPaths : paths
      let row = words?.row(action)
      Button(action.title + suffix, systemImage: action.systemImage) { Task { await library.run(action, on: targets) } }
        .kitMenuHint(row?.hint)
        .kitMenuPreview(row?.preview, picture: row?.picture)
        .disabled(targets.allSatisfy {
          library.remoteActivity[$0] != nil || (RepositoryLibrary.isRemote($0) && GitSecurity.level.otherDeviceRefusal != nil)
        })
    }
  }
}

/// What Fetch, Pull and Push say in a menu that knows the counts: the end ("3 commits") and the panel's sentence.
struct RemoteActionWords {
  struct Row {
    var hint: String?
    var preview: String?
    var picture: BranchPicture?
  }

  let row: (RemoteAction) -> Row
}

extension View {
  /// The row's sentence, with its picture when there is one.
  @ViewBuilder
  func kitMenuPreview(_ text: String?, picture: BranchPicture?) -> some View {
    if let text, let picture {
      kitMenuPreview(text) { picture }
    } else {
      kitMenuPreview(text)
    }
  }
}

/// What a group's tooltip says: where it is and how many repositories it holds, then those that need attention.
struct GroupHelp: Equatable {
  struct Line: Equatable {
    let path: String
    let name: String
    let summary: RepositorySummary
  }

  let meta: String
  let attention: [Line]
}

/// The repositories in a group that need attention, one a row with the sidebar's marks lined up on the right.
struct GroupHelpDetail: View {
  static let limit = 10
  let help: GroupHelp

  var body: some View {
    if help.attention.isEmpty {
      Text("All up to date").foregroundStyle(.kitSecondary)
    } else {
      VStack(alignment: .leading, spacing: 5) {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
          ForEach(help.attention.prefix(Self.limit), id: \.path) { line in
            GridRow {
              Text(line.name).lineLimit(1)
              StatusMarks(summary: line.summary).gridColumnAlignment(.trailing)
            }
          }
        }
        if help.attention.count > Self.limit {
          Text("and \(help.attention.count - Self.limit) more").kitFont(.caption)
        }
      }
    }
  }
}

/// A repository: its project's icon (or letter tile), name and state. The open one is the kit's current row; others
/// selected with it are tinted.
struct RepositoryRow: View, Equatable {
  let repository: SavedRepository
  /// The vault's PNG of the project's app icon.
  var icon: Data?
  let summary: RepositorySummary?
  let isCurrent: Bool
  var isSelected = false
  var activity: RemoteAction?
  /// How the last fetch, pull or push from the sidebar ended: the row plays its effect.
  var outcome: RemoteOutcome?
  /// What a click does: open it, or (⌘, ⇧) select it with others (`RepositoryRowActions.click`).
  let actions: RepositoryRowActions

  /// The actions box stays the same; the rest is what the row draws (the repository's own values are observed).
  nonisolated static func == (a: Self, b: Self) -> Bool {
    MainActor.assumeIsolated {
      a.repository === b.repository && a.icon == b.icon && a.summary == b.summary && a.isCurrent == b.isCurrent
        && a.isSelected == b.isSelected && a.activity == b.activity && a.outcome == b.outcome && a.actions === b.actions
    }
  }

  var body: some View {
    SidebarRow(repository.name) {
      let status: WorkStatus = activity == nil ? .idle : .working
      Avatar(name: repository.name, imageData: icon, kind: .thing, status: status, size: 18)
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
    .action { [actions, repository] in actions.click(repository.path) }
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous).fill(Hue.accent.soft())
      }
    }
    .animation(.kit, value: isCurrent)
    .animation(.kit, value: isSelected)
    .effect(outcome?.effect ?? .pop, on: outcome?.count)
    .kitHelp(
      repository.name,
      meta: [repository.path, summary.map(StatusMarks.description)].compactMap { $0 }.filter { !$0.isEmpty }
        .joined(separator: "\n"))
    .accessibilityAddTraits(isCurrent || isSelected ? .isSelected : [])
  }
}

/// What the Repositories list's rows and group headers do, in a box the list fills each time it updates: the rows and
/// their menus hold the box rather than closures, so a row whose state didn't change keeps the same inputs and isn't
/// built again (new closures made every row, its menu and its tooltip update on each click or selection change).
@MainActor final class RepositoryRowActions {
  var click: (String) -> Void = { _ in }
  var menu: (String) -> AnyView = { _ in AnyView(EmptyView()) }
  var groupMenu: (VaultProjectGroup, [SavedRepository]) -> AnyView = { _, _ in AnyView(EmptyView()) }
  var toggle: (VaultProjectGroup) -> Void = { _ in }
  var rename: (VaultProjectGroup, String) -> Void = { _, _ in }
  var endRename: () -> Void = {}

  func configured(
    click: @escaping (String) -> Void, menu: @escaping (String) -> AnyView,
    groupMenu: @escaping (VaultProjectGroup, [SavedRepository]) -> AnyView,
    toggle: @escaping (VaultProjectGroup) -> Void, rename: @escaping (VaultProjectGroup, String) -> Void,
    endRename: @escaping () -> Void
  ) -> Self {
    self.click = click
    self.menu = menu
    self.groupMenu = groupMenu
    self.toggle = toggle
    self.rename = rename
    self.endRename = endRename
    return self
  }
}

/// A repository row's context menu, built from the box when it opens.
private struct RepositoryRowMenu: ViewModifier {
  let path: String
  let actions: RepositoryRowActions

  func body(content: Content) -> some View {
    content.kitContextMenu { [actions, path] in actions.menu(path) }
  }
}

/// A group header's rename field and context menu, from the box.
private struct GroupExtras: ViewModifier {
  let group: VaultProjectGroup
  let members: [SavedRepository]
  let isRenaming: Bool
  let actions: RepositoryRowActions

  func body(content: Content) -> some View {
    content
      .kitRename(isRenaming: .init(get: { isRenaming }, set: { [actions] in if !$0 { actions.endRename() } })) {
        [actions, group] in actions.rename(group, $0)
      }
      .kitContextMenu { [actions, group, members] in actions.groupMenu(group, members) }
  }
}
