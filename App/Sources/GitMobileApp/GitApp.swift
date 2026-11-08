import ComponentKit
import GitEngine
import GitHubKit
import GitKit
import GitRemote
import GitUI
import SwiftUI
import VaultKit
import VaultUI

/// Git on iPhone and iPad. Repositories on this device (in the app's folder, which the Files app shows) are read and
/// written by GitEngine, git in Swift: clone, changes, commit, branches, pull and push. Repositories on the user's
/// Macs (the vault's projects on devices of their Hub, or folders on any SSH host saved in the Vault app) run the
/// Mac's own git over SSH through GitKit, so everything the Mac app does with changes works there.
public struct GitApp: App {
  public init() {
    // The devices and their projects sync on their own, and this device shows up on the others to be let in.
    Vault.shared.startSync()
    try? Vault.shared.store?.publishDeviceKey()
    GitSecurity.install()
  }

  public var body: some Scene {
    WindowGroup {
      RepositoriesView()
        .environment(GitHubAccount.app)
        .vaultHostKeyRequests()
        .componentKit()
    }
  }
}

/// The kit's split view on iPad: the repositories in the sidebar, the picked one beside it. On iPhone the list is the
/// root of a stack and the picked repository is pushed.
struct RepositoriesView: View {
  @State private var vault = Vault.shared
  @State private var local = LocalRepositories.shared
  @State private var selection: RepositorySource.ID?
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @State private var sheet: LibrarySheet?
  /// iPhone's stack: the open repository, then its diffs and commits.
  @State private var path = NavigationPath()
  /// Bumped when a folder is added on a Mac, so the list reads the saved ones again.
  @State private var savedRevision = 0
  /// Asks for the name and email at the first commit that needs them.
  @State private var profiles = VaultProfileRequest()
  @State private var groups = RemoteGroups()
  /// Settings: on iPad in the detail until a repository is picked or Done, on iPhone pushed on the stack, the way the
  /// kit then pushes its panes (`navigationDestination(isPresented:)`).
  @State private var showsSettings = false
  @State private var columnsBeforeSettings = NavigationSplitViewVisibility.all
  @Environment(\.kitIdiom) private var idiom
  @Environment(\.scenePhase) private var scenePhase

  private var remote: [RemoteRepository] {
    _ = savedRevision
    return RemoteRepositories.all(vault: vault)
  }

  /// The vault's projects on the user's other devices, in the groups every app shows them in.
  private var remoteTree: VaultProjectTree {
    let ids = Set(remote.map(\.id))
    return vault.projectTree.filter { ids.contains($0.id) }
  }

  private var sources: [RepositorySource] {
    local.repositories.map(RepositorySource.local) + remote.map(RepositorySource.remote)
  }

  var body: some View {
    root
      // Settings isn't an overlay: it's pushed on iPhone and takes the detail on iPad (`showsSettings`).
      .kitSheet(item: Binding(get: { sheet == .settings ? nil : sheet }, set: { sheet = $0 })) { sheet in
        switch sheet {
        case .clone: CloneSheet { selection = RepositorySource.local($0).id }
        case .create: NewRepositorySheet { selection = RepositorySource.local($0).id }
        case .addRemote:
          AddRemoteSheet { saved in
            savedRevision += 1
            selection = "remote:saved:" + saved.id
          }
        case .settings: EmptyView()
        }
      }
      .onChange(of: sheet) { _, picked in
        guard picked == .settings else { return }
        sheet = nil
        showsSettings = true
      }
      .vaultProfileRequests(profiles)
      .environment(profiles)
      .onChange(of: scenePhase) { _, phase in
        // Folders added in the Files app meanwhile.
        if phase == .active { local.reload() }
      }
  }

  @ViewBuilder private var root: some View {
    Group {
      if idiom == .phone { stack } else { split }
    }
    .task { Task { await AutoFetch.shared.fetchAtStartup(local.repositories) } }
    .task {
      #if DEBUG
        DebugLaunch.addGroupedProjects(to: vault)
        if let id = await DebugLaunch.selected(in: sources) { selection = id }
        if let sheet = DebugLaunch.sheet { self.sheet = sheet }
      #endif
    }
  }

  private var sidebar: some View {
    RepositoriesSidebar(
      local: local.repositories, remote: remote, tree: remoteTree, groups: groups, selection: $selection,
      columnVisibility: $columnVisibility, sheet: $sheet
    ) { source in
      remove(source)
    }
  }

  /// iPhone: one stack, the list at its root and the picked repository pushed onto it, so back always closes the
  /// repository. (A collapsed split view reports its sidebar column whenever the detail's own stack pops, and value
  /// links don't push under a destination pushed by `navigationDestination(item:)`.)
  private var stack: some View {
    NavigationStack(path: $path) {
      sidebar
        .navigationDestination(for: OpenRepository.self) { open in
          if let source = sources.first(where: { $0.id == open.id }) {
            RepositoryScreen(source: source).id(source.id)
          }
        }
        .navigationDestination(isPresented: $showsSettings) { SettingsScreen() }
    }
    .onChange(of: selection) { _, selection in
      guard let selection else { return }
      path = NavigationPath([OpenRepository(id: selection)])
    }
    // Back on the root list: no row stays picked (tapping it again opens it again).
    .onChange(of: path.count) { _, count in
      if count == 0 { selection = nil }
    }
  }

  private var split: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebar
        .toolbar(removing: .sidebarToggle)
        .kitSidebarColumn()
    } detail: {
      if showsSettings {
        NavigationStack { SettingsScreen { showsSettings = false } }
      } else {
        NavigationStack {
          if let source = sources.first(where: { $0.id == selection }) {
            RepositoryScreen(source: source).id(source.id)
          } else {
            RepositoriesWelcome(sources: sources.filter(isListed), selection: $selection, sheet: $sheet)
          }
        }
        .kitSidebarToggle(columnVisibility: $columnVisibility)
      }
    }
    .onChange(of: selection) { _, selected in
      if selected != nil { showsSettings = false }
    }
    // Settings brings its own sidebar: beside this one its columns don't fit an iPad in portrait, and were cut off.
    .onChange(of: showsSettings) { _, shows in
      if shows {
        columnsBeforeSettings = columnVisibility
        columnVisibility = .detailOnly
      } else {
        columnVisibility = columnsBeforeSettings
      }
    }
  }

  /// Not left out of the list by a group's Hide or Remove.
  private func isListed(_ source: RepositorySource) -> Bool {
    guard case .remote(let repository) = source else { return true }
    return !groups.hidden.contains(repository.id) && !groups.removed.contains(repository.id)
  }

  private func remove(_ source: RepositorySource) {
    if selection == source.id { selection = nil }
    switch source {
    case .local(let repository): try? local.delete(repository)
    case .remote(let repository):
      RemoteRepositories.remove(id: repository.id)
      savedRevision += 1
    }
  }
}

/// The repository iPhone's stack shows.
struct OpenRepository: Hashable {
  let id: RepositorySource.ID
}

/// The sheets the repository list opens.
enum LibrarySheet: String, Identifiable {
  case clone, create, addRemote, settings
  var id: Self { self }
}

/// The main screen while no repository is open: Clone, New and Add on a Mac, and every repository (a tap opens one).
struct RepositoriesWelcome: View {
  let sources: [RepositorySource]
  @Binding var selection: RepositorySource.ID?
  @Binding var sheet: LibrarySheet?

  var body: some View {
    KitWelcome(
      emptyTitle: "No Repositories Yet",
      emptyMessage:
        "Clone one to this device, or open one on your Mac: projects on the devices of your Hub show up here, and any SSH host in the Vault app works too."
    ) {
      WelcomeAction("Clone Repository…", detail: "From GitHub or any HTTPS or SSH URL", systemImage: "square.and.arrow.down") {
        sheet = .clone
      }
      WelcomeAction("New Repository…", detail: "An empty one on this device", systemImage: "plus.square") {
        sheet = .create
      }
      WelcomeAction("Open on a Mac…", detail: "A folder on one of your SSH hosts", systemImage: "desktopcomputer") {
        sheet = .addRemote
      }
    } recents: {
      ForEach(sources) { source in
        switch source {
        case .local(let repository):
          RecentItem(repository.name, subtitle: "On this device", systemImage: "internaldrive", id: source.id) {
            selection = source.id
          }
        case .remote(let repository):
          RecentItem(
            repository.name, subtitle: repository.targets.map(\.name).joined(separator: ", "),
            systemImage: repository.icon == nil ? "desktopcomputer" : nil,
            imageData: repository.icon, id: source.id
          ) { selection = source.id }
        }
      }
    }
    .listTitle("Repositories")
    .kitPane(.content)
  }
}

/// The repositories as the kit's sidebar: a card for those on this device, the vault's projects on the user's other
/// devices in their groups (VaultUI's projects section, as every app lists them), and the folders opened on a Mac
/// here; search filters them all, and the bar says how many devices Git reaches.
struct RepositoriesSidebar: View {
  let local: [LocalRepository]
  let remote: [RemoteRepository]
  /// The vault's projects among `remote`, in their groups.
  let tree: VaultProjectTree
  @Bindable var groups: RemoteGroups
  @Binding var selection: RepositorySource.ID?
  @Binding var columnVisibility: NavigationSplitViewVisibility
  @Binding var sheet: LibrarySheet?
  let remove: (RepositorySource) -> Void
  @State private var search = ""
  @State private var pendingRemoval: RepositorySource?
  @State private var showsAddMenu = false
  @State private var collapsedGroups: Set<String> = []
  /// On Your Devices, folded at launch.
  @State private var isRemoteOpen = false
  /// One switch with the Mac's Show Hidden.
  @KitStorage("ShowsHiddenRepositories") private var showsHidden = false
  @Environment(\.kitIdiom) private var idiom

  /// What the groups' menus act on: all but the removed.
  private var listed: VaultProjectTree { tree.filter { !groups.removed.contains($0.id) } }

  /// Not hidden (or Show Hidden is on), or the open one.
  private func isShown(_ project: VaultProject) -> Bool {
    showsHidden || !groups.hidden.contains(project.id) || selection == "remote:" + project.id
  }

  /// The folders opened on a Mac here, which aren't vault projects.
  private var opened: [RemoteRepository] { remote.filter { tree.node(id: $0.id) == nil } }

  /// The picked vault project's id, for the projects section.
  private var projectSelection: Binding<String?> {
    Binding(
      get: { selection.flatMap { $0.hasPrefix("remote:") ? String($0.dropFirst("remote:".count)) : nil } },
      set: { id in selection = id.map { "remote:" + $0 } })
  }

  private func matches(_ name: String) -> Bool { search.isEmpty || name.localizedCaseInsensitiveContains(search) }

  /// The devices the remote repositories are on.
  private var deviceCount: Int { Set(remote.flatMap { $0.targets.map(\.id) }).count }

  var body: some View {
    KitSidebar(
      selection: $selection, searchText: $search, searchPrompt: "Search Repositories",
      columnVisibility: $columnVisibility
    ) {
      KitSection(
        idiom == .phone ? "On This iPhone" : "On This iPad",
        meta: [local.count == 1 ? String(localized: "1 repository") : String(localized: "\(local.count) repositories")], systemImage: "internaldrive",
        hue: .orange
      ) {
        ForEach(local.filter { matches($0.name) }, id: \.url) { repository in
          let source = RepositorySource.local(repository)
          SidebarRow(value: source.id, repository.name, subtitle: "Files › Git") {
            Avatar(name: repository.name, kind: .thing, size: 32)
          } trailing: {
            chevron
          }
          .kitContextMenu {
            Button("Delete…", systemImage: "trash", role: .destructive) { pendingRemoval = source }
          }
        }
        if local.isEmpty {
          Text("Clone a repository or create one: it lives in the Files app, under Git.")
            .kitFont(.caption).foregroundStyle(.kitSecondary).padding(10)
        }
      } accessory: {
        Button("Add", systemImage: "plus") { showsAddMenu = true }
          .labelStyle(.iconOnly)
          .kitMenu(isPresented: $showsAddMenu) {
            Button("Clone Repository…", systemImage: "square.and.arrow.down") { sheet = .clone }
            Button("New Repository…", systemImage: "plus.square") { sheet = .create }
          }
      }
      VaultProjectsSection(
        listed.filter { matches($0.name) && isShown($0) }, selection: projectSelection, key: "remoteProjects",
        collapsedGroups: $collapsedGroups
      ) {
        titleMenu
      }
      .title("On Your Devices")
      // A search still shows what it finds, and an empty list says why.
      .isExpanded(.init(get: { isRemoteOpen || !search.isEmpty || listed.projects().isEmpty }, set: { isRemoteOpen = $0 }))
      .renamableGroups { group, name in
        var group = group
        group.name = name
        Vault.shared.save(group)
      }
      .groupMenu { group, rename in groupMenu(group, rename: rename) }
      .groupTrailing(whenOpen: true) { _, projects in groupCounts(projects) }
      .groupStatus { _, projects in
        members(projects).contains { groups.activity[$0.id] != nil } ? .working : .idle
      }
      .rowDimmed { groups.hidden.contains($0.id) }
      .rowSubtitle { project in remote.first { $0.id == project.id }.map(subtitle) }
      .trailing { project in
        HStack(spacing: 8) {
          if let repository = remote.first(where: { $0.id == project.id }) { lastSeen(repository) }
          chevron
        }
      }
      .accessory {
        Button("Open on a Mac", systemImage: "plus") { sheet = .addRemote }
          .labelStyle(.iconOnly)
      }
      .emptyState {
        Text(
          tree.projects().isEmpty
            ? "Projects on the devices of your Hub appear here, in their groups. Open a folder on any SSH host with Open on a Mac."
            : search.isEmpty ? "All hidden or removed." : "No repositories match “\(search)”."
        )
        .kitFont(.caption).foregroundStyle(.kitSecondary).padding(10)
      }
      if !opened.isEmpty {
        KitSection(
          "Opened on a Mac",
          meta: [opened.count == 1 ? String(localized: "1 repository") : String(localized: "\(opened.count) repositories")], systemImage: "desktopcomputer",
          hue: .blue
        ) {
          ForEach(opened.filter { matches($0.name) }) { repository in
            let source = RepositorySource.remote(repository)
            SidebarRow(value: source.id, repository.name, subtitle: subtitle(repository)) {
              Avatar(name: repository.name, kind: .thing, size: 32)
            } trailing: {
              HStack(spacing: 8) {
                lastSeen(repository)
                chevron
              }
            }
            .kitContextMenu {
              Button("Remove from List", systemImage: "minus.circle") { remove(source) }
            }
          }
        }
      }
    } bottomBar: {
      EmptyView()
    }
    .status {
      HStack(spacing: 6) {
        StatusDot(hue: deviceCount > 0 ? .green : .gray)
        Text(deviceCount == 0 ? "No devices" : deviceCount == 1 ? "1 device" : "\(deviceCount) devices")
        Spacer(minLength: 0)
        Button("Settings", systemImage: "gearshape") { sheet = .settings }
          .labelStyle(.iconOnly)
          .buttonStyle(.kitPlain)
      }
    }
    .navigationTitle("Git")
    .kitNotice(item: $groups.failure, title: \.title, message: \.message)
    .kitConfirmation(
      "Delete \(pendingRemoval?.name ?? "")?",
      isPresented: .init(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
      message: "Its folder is deleted from this device, with commits that were never pushed.", systemImage: "trash",
      confirm: "Delete"
    ) {
      if let source = pendingRemoval { remove(source) }
    }
  }

  /// Its branch when its device last said (the vault's status), then the devices it is on, as Code lists its
  /// projects: "via Hub" after each repeated itself on every row.
  private func subtitle(_ repository: RemoteRepository) -> String {
    let places = repository.targets.map(\.name).joined(separator: ", ")
    guard let branch = repository.lastSeen?.status.branch else { return places }
    return branch + " · " + places
  }

  /// What's running on it, else its changes and commits to push and pull when this device or its own last looked.
  @ViewBuilder private func lastSeen(_ repository: RemoteRepository) -> some View {
    if let activity = groups.activity[repository.id] {
      Text("\(activity.title)ing…").kitFont(.caption).foregroundStyle(.kitSecondary)
    } else if let summary = groups.summary(of: repository) {
      SyncCounts(changes: summary.changeCount, ahead: summary.ahead, behind: summary.behind)
    }
  }

  // MARK: Groups

  private func members(_ projects: [VaultProject]) -> [RemoteRepository] {
    projects.compactMap { project in remote.first { $0.id == project.id } }
  }

  /// The summed state of a group's repositories, the hidden ones aside, as the Mac's groups show.
  private func groupCounts(_ projects: [VaultProject]) -> some View {
    let summary = RepositorySummary(
      combining: members(projects).filter { !groups.hidden.contains($0.id) }.compactMap(groups.summary))
    return SyncCounts(changes: summary.changeCount, ahead: summary.ahead, behind: summary.behind)
  }

  /// The Mac's group menu, but for Show in Finder: there's no folder here.
  @ViewBuilder private func groupMenu(_ group: VaultProjectGroup, rename: @escaping () -> Void) -> some View {
    let tree = listed
    let members = members(tree.projects(in: group.id))
    let ids = members.map(\.id)
    let parent = tree.parent(of: group.id)
    // Groups it can move into: not itself, not one inside it, not the one it is in.
    let destinations = tree.groups.filter { !tree.isWithin($0.id, group.id) && $0.id != parent }
    ForEach([RemoteAction.fetch, .pull, .push], id: \.self) { action in
      let targets = action == .push ? members.filter { groups.summary(of: $0).map { $0.hasUpstream && $0.ahead > 0 } ?? false } : members
      Button(action.title + " All", systemImage: action.systemImage) { Task { await groups.run(action, on: targets) } }
        .disabled(GitSecurity.level.otherDeviceRefusal != nil || targets.allSatisfy { groups.activity[$0.id] != nil })
    }
    Divider()
    Button("Rename…", systemImage: "pencil", action: rename)
    Button("Ungroup", systemImage: "folder.badge.minus") {
      withAnimation(.kit) { Vault.shared.perform { try $0.ungroupProjects(group.id) } }
      collapsedGroups.remove(group.id)
    }
    if !destinations.isEmpty {
      KitSubmenu("Move to Group", systemImage: "folder") {
        ForEach(destinations) { destination in
          Button(title(of: destination, in: tree)) {
            withAnimation(.kit) { Vault.shared.perform { try $0.moveProjects([group.id], into: destination.id) } }
          }
        }
      }
    }
    if parent != nil {
      Button("Move Out of Group", systemImage: "arrow.up.left") {
        withAnimation(.kit) { Vault.shared.perform { try $0.moveProjectsOut([group.id]) } }
      }
    }
    Divider()
    if ids.allSatisfy(groups.hidden.contains) {
      Button("Unhide Group", systemImage: "eye") { withAnimation(.kit) { groups.setHidden(ids, false) } }
    } else {
      Button("Hide Group", systemImage: "eye.slash") { withAnimation(.kit) { groups.setHidden(ids, true) } }
    }
    Button("Remove Group from List", systemImage: "minus.circle") {
      if let selection, ids.contains(where: { "remote:" + $0 == selection }) { self.selection = nil }
      withAnimation(.kit) { groups.remove(ids) }
    }
  }

  /// "v57 › Agentus (Developer)": a group with the groups it is in, and its note.
  private func title(of group: VaultProjectGroup, in tree: VaultProjectTree) -> String {
    let title = (tree.ancestors(of: group.id).map(\.name) + [group.name]).joined(separator: " › ")
    guard let note = group.note, !note.isEmpty else { return title }
    return "\(title) (\(note))"
  }

  /// The way back to what the groups' menus left out.
  @ViewBuilder private var titleMenu: some View {
    let hidden = listed.projects().count { groups.hidden.contains($0.id) }
    let removed = tree.projects().map(\.id).filter(groups.removed.contains)
    if hidden > 0 || !removed.isEmpty {
      if hidden > 0 {
        Button(showsHidden ? "Hide Hidden Repositories" : "Show \(hidden) Hidden", systemImage: "eye") {
          withAnimation(.kit) { showsHidden.toggle() }
        }
      }
      if !removed.isEmpty {
        Button("Restore \(removed.count) Removed", systemImage: "arrow.uturn.backward") {
          withAnimation(.kit) { groups.restore(removed) }
        }
      }
    }
  }

  @ViewBuilder private var chevron: some View {
    // iPhone: a row pushes its repository.
    if idiom == .phone {
      Image(systemName: "chevron.right")
        .font(KitFont.callout.font.weight(.semibold))
        .foregroundStyle(.kitTertiary)
    }
  }
}
