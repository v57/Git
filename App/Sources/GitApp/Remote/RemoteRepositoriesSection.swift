import ComponentKit
import GitKit
import GitRemote
import GitUI
import SwiftData
import SwiftUI
import VaultKit
import VaultUI

/// On Your Devices: the vault's projects on the user's other devices that aren't on this Mac, in the groups every
/// app shows them in (VaultUI's projects section, the list alone), then any other repository on another machine (a
/// debug run's). Picking one opens it as any repository: its git runs on that device over SSH (`SSHGitTransport`),
/// signed in with this Mac's key (a Mac lets it in through Settings ▸ Remote) or the host's saved password. Shown
/// only when there are any.
struct RemoteRepositoriesSection: View {
  @Environment(RepositoryLibrary.self) private var library
  @Environment(\.modelContext) private var context
  @Binding var selection: String?
  /// The repository on screen, whose Workspace goes under its row in `.inline`.
  let shown: String?
  let filter: String
  @State private var collapsedGroups: Set<String> = []
  /// Folded at launch.
  @State private var isExpanded = false
  @KitStorage(VaultProjectsLayout.gitKey) private var projectsLayout = VaultProjectsLayout.separate
  /// One switch with the Repositories list's Show Hidden.
  @KitStorage("ShowsHiddenRepositories") private var showsHidden = false

  private func matches(_ name: String) -> Bool { filter.isEmpty || name.localizedCaseInsensitiveContains(filter) }

  /// Not hidden (or Show Hidden is on), or the open one.
  private func isShown(_ project: VaultProject, in remote: [RemoteRepository]) -> Bool {
    showsHidden || !library.hiddenRemotes.contains(project.id)
      || remote.contains { $0.id == project.id && RepositoryLibrary.remoteKey($0) == selection }
  }

  /// The picked project's id, for the projects section.
  private var projectSelection: Binding<String?> {
    Binding(
      get: { selection.flatMap { library.remoteRepository($0)?.id } },
      set: { id in
        guard let id, let repository = library.remoteRepositories.first(where: { $0.id == id }) else { return }
        select(repository)
      })
  }

  /// The repository's Workspace rows, when they go under its row and it's open.
  @ViewBuilder private func inlineWorkspace(_ repository: RemoteRepository?) -> some View {
    if projectsLayout == .inline, let repository, shown == RepositoryLibrary.remoteKey(repository),
      let session = library.loadedSession(for: RepositoryLibrary.remoteKey(repository))
    {
      InlineWorkspaceRows(session: session)
    }
  }

  var body: some View {
    let remote = library.remoteRepositories
    if !remote.isEmpty {
      let ids = Set(remote.map(\.id))
      let all = library.vault.projectTree.filter { ids.contains($0.id) }
      // What the groups' menus and sort options act on: all but the removed.
      let tree = all.filter { !library.removedRemotes.contains($0.id) }
      let others = remote.filter { all.node(id: $0.id) == nil }
      if !all.projects().isEmpty {
        VaultProjectsSection(
          tree.filter { matches($0.name) && isShown($0, in: remote) }, selection: projectSelection, key: "remoteProjects",
          collapsedGroups: $collapsedGroups
        ) {
          ProjectsLayoutMenu()
          titleMenu(all: all, tree: tree)
        }
        .title("On Your Devices")
        .emptyState {
          Text(filter.isEmpty ? "All hidden or removed." : "No repositories match “\(filter)”.")
            .kitFont(.callout).foregroundStyle(.kitSecondary)
        }
        .renamableGroups { group, name in library.rename(group, to: name) }
        .groupMenu { group, rename in groupMenu(group, in: tree, rename: rename) }
        .groupTrailing(whenOpen: true) { _, projects in StatusMarks(summary: groupSummary(projects, remote)) }
        .groupStatus { _, projects in
          members(projects, remote).contains { library.remoteActivity[RepositoryLibrary.remoteKey($0)] != nil }
            ? .working : .idle
        }
        .groupHelp { group, projects in groupMeta(group, projects: projects, in: tree) } detail: { _, projects in
          GroupHelpDetail(help: groupHelp(projects, remote))
        }
        .rowDimmed { library.hiddenRemotes.contains($0.id) }
        // A search still shows what it finds.
        .isExpanded(.init(get: { isExpanded || !filter.isEmpty }, set: { isExpanded = $0 }))
        .rowContent(projectsLayout == .inline) { project in inlineWorkspace(remote.first { $0.id == project.id }) }
        .rowSubtitle { project in remote.first { $0.id == project.id }.map(subtitle) }
        .trailing { project in
          if let repository = remote.first(where: { $0.id == project.id }) { marks(repository) }
        }
        .onChange(of: selection, initial: true) { _, new in
          if projectsLayout == .folding, new != nil { isExpanded = false }
          // Its Workspace goes under its row here, so the list stays open around it.
          if projectsLayout == .inline, let new, library.remoteRepository(new) != nil { isExpanded = true }
        }
        .onChange(of: projectsLayout) { _, new in isExpanded = !(new == .folding && selection != nil) }
      }
      if !others.isEmpty {
        KitSection(
          tree.projects().isEmpty ? "On Your Devices" : "On Other Machines",
          meta: [others.count == 1 ? String(localized: "1 repository") : String(localized: "\(others.count) repositories")], systemImage: "desktopcomputer",
          hue: .blue
        ) {
          ForEach(others.filter { matches($0.name) }) { repository in
            SidebarRow(repository.name, subtitle: subtitle(repository)) {
              Avatar(name: repository.name, kind: .thing, size: 18)
            } trailing: {
              marks(repository)
            }
            .isCurrent(selection == RepositoryLibrary.remoteKey(repository))
            .action { select(repository) }
            .kitHelp("\(repository.name)", meta: repository.targets.first.map { "\($0.directory) on \($0.name)" })
            inlineWorkspace(repository)
          }
        }
        .kitSticky(top: .titleWhileVisible, bottom: .none)
      }
    }
  }

  // MARK: Groups

  private func members(_ projects: [VaultProject], _ remote: [RemoteRepository]) -> [RemoteRepository] {
    projects.compactMap { project in remote.first { $0.id == project.id } }
  }

  /// The summed state of a group's repositories, the hidden ones aside, as the Repositories list's groups show.
  private func groupSummary(_ projects: [VaultProject], _ remote: [RemoteRepository]) -> RepositorySummary {
    RepositorySummary(
      combining: members(projects, remote).filter { !library.hiddenRemotes.contains($0.id) }.compactMap(library.remoteSummary))
  }

  private func groupHelp(_ projects: [VaultProject], _ remote: [RemoteRepository]) -> GroupHelp {
    let attention = members(projects, remote).filter { !library.hiddenRemotes.contains($0.id) }.compactMap { repository in
      library.remoteSummary(repository).flatMap {
        $0.needsAttention
          ? GroupHelp.Line(path: RepositoryLibrary.remoteKey(repository), name: repository.name, summary: $0) : nil
      }
    }
    return GroupHelp(meta: "", attention: attention)
  }

  /// Its place among the groups (nothing when that is just its name) and how many repositories it holds.
  private func groupMeta(_ group: VaultProjectGroup, projects: [VaultProject], in tree: VaultProjectTree) -> String {
    let place = title(of: group, in: tree)
    let count = projects.count == 1 ? String(localized: "1 repository") : String(localized: "\(projects.count) repositories")
    return [place == group.name ? nil : place, count].compactMap { $0 }.joined(separator: " · ")
  }

  private func title(of group: VaultProjectGroup, in tree: VaultProjectTree) -> String {
    (tree.ancestors(of: group.id).map(\.name) + [group.name]).joined(separator: " › ")
  }

  /// The Repositories list's group menu, for repositories on other devices (no folder here to show in Finder).
  @ViewBuilder private func groupMenu(_ group: VaultProjectGroup, in tree: VaultProjectTree, rename: @escaping () -> Void)
    -> some View
  {
    let remote = members(tree.projects(in: group.id), library.remoteRepositories)
    let ids = remote.map(\.id)
    let keys = remote.map(RepositoryLibrary.remoteKey)
    let parent = tree.parent(of: group.id)
    // Groups it can move into: not itself, not one inside it, not the one it is in.
    let destinations = tree.groups.filter { !tree.isWithin($0.id, group.id) && $0.id != parent }
    RemoteActionButtons(
      paths: keys,
      pushPaths: remote.filter { repository in
        library.remoteSummary(repository).map { $0.hasUpstream && $0.ahead > 0 } ?? false
      }.map(RepositoryLibrary.remoteKey),
      suffix: " All")
    Divider()
    Button("Rename…", systemImage: "pencil", action: rename)
    Button("Ungroup", systemImage: "folder.badge.minus") { withAnimation(.kit) { library.ungroup(group) } }
    if !destinations.isEmpty {
      KitSubmenu("Move to Group", systemImage: "folder") {
        ForEach(destinations) { destination in
          Button(destinationTitle(destination, in: tree)) {
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
    if ids.allSatisfy(library.hiddenRemotes.contains) {
      Button("Unhide Group", systemImage: "eye") { withAnimation(.kit) { library.setRemoteHidden(ids, false) } }
    } else {
      Button("Hide Group", systemImage: "eye.slash") { withAnimation(.kit) { library.setRemoteHidden(ids, true) } }
    }
    Button("Remove Group from List", systemImage: "minus.circle") {
      if let selection, keys.contains(selection) { self.selection = nil }
      withAnimation(.kit) { library.removeRemotes(ids) }
    }
  }

  /// "v57 › Agentus (Developer)": a group with the groups it is in, and its note.
  private func destinationTitle(_ group: VaultProjectGroup, in tree: VaultProjectTree) -> String {
    let title = title(of: group, in: tree)
    guard let note = group.note, !note.isEmpty else { return title }
    return "\(title) (\(note))"
  }

  /// The way back to what the groups' menus left out.
  @ViewBuilder private func titleMenu(all: VaultProjectTree, tree: VaultProjectTree) -> some View {
    let hidden = tree.projects().count { library.hiddenRemotes.contains($0.id) }
    let removed = all.projects().map(\.id).filter(library.removedRemotes.contains)
    if hidden > 0 || !removed.isEmpty {
      Divider()
      if hidden > 0 {
        Button(showsHidden ? "Hide Hidden Repositories" : "Show \(hidden) Hidden", systemImage: "eye") {
          withAnimation(.kit) { showsHidden.toggle() }
        }
      }
      if !removed.isEmpty {
        Button("Restore \(removed.count) Removed", systemImage: "arrow.uturn.backward") {
          withAnimation(.kit) { library.removedRemotes.subtract(removed) }
        }
      }
    }
  }

  private func select(_ repository: RemoteRepository) {
    withKitAnimation {
      library.showsAllRepositories = false
      selection = RepositoryLibrary.remoteKey(repository)
    }
  }

  /// Its branch when its device last said (the vault's status), then the devices it is on.
  private func subtitle(_ repository: RemoteRepository) -> String {
    guard let branch = library.remoteSummary(repository)?.branch else { return repository.places }
    return branch + " · " + repository.places
  }

  /// Connecting, couldn't connect, or the repository's state at a glance: live once it's open, else as its device
  /// last said.
  @ViewBuilder private func marks(_ repository: RemoteRepository) -> some View {
    let key = RepositoryLibrary.remoteKey(repository)
    let outcome = library.remoteOutcomes[key]
    Group {
      if let activity = library.remoteActivity[key] {
        Text("\(activity.title)ing…")
      } else {
        switch library.remoteStates[key] {
        case .connecting?:
          LiveIcon(systemImage: "network", hue: .blue, status: .working, size: 14)
        case .failed?:
          StatusDot(hue: .red)
        case nil:
          if let summary = library.remoteSummary(repository) { StatusMarks(summary: summary) }
        }
      }
    }
    .effect(outcome?.effect ?? .pop, on: outcome?.count)
  }
}

/// A repository on another device until its session is in: connecting, or why it couldn't, with Try Again; under
/// either, how its device last saw it (the vault's status: branch, counts, the first files).
struct RemoteConnectionScreen: View {
  @Environment(RepositoryLibrary.self) private var library
  let key: String

  var body: some View {
    let repository = library.remoteRepository(key)
    let name = repository?.name ?? String(localized: "Repository")
    let lastSeen = repository?.lastSeen
    ZStack {
      switch library.remoteStates[key] {
      case .failed(let message)?:
        EmptyState(systemImage: "exclamationmark.triangle", title: "Couldn’t Open \(name)", message: "\(message)") {
          lastSeenDetail(lastSeen)
        } actions: {
          Button("Try Again") { Task { await library.reconnect(key) } }
            .buttonStyle(.kitPrimary)
        }
        .transition(.page)
      case .connecting(let message)?:
        EmptyState(systemImage: "desktopcomputer", title: name, message: message, status: .working) {
          lastSeenDetail(lastSeen)
        } actions: {}
        .transition(.page)
      case nil:
        EmptyState(
          systemImage: "desktopcomputer", title: "\(name)",
          message: repository.map { "Connecting to \($0.targets.first?.name ?? "the device")…" }, status: .working
        ) {
          lastSeenDetail(lastSeen)
        } actions: {}
        .transition(.page)
      }
    }
    .animation(.kit, value: library.remoteStates[key])
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .kitToolbar(name) { EmptyView() } tools: {}
  }

  @ViewBuilder private func lastSeenDetail(_ lastSeen: (device: String, status: VaultProject.Status)?) -> some View {
    if let lastSeen { LastSeenChanges(device: lastSeen.device, status: lastSeen.status).padding(.top, 8) }
  }
}
