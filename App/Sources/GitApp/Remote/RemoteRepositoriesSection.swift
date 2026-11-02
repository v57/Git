import ComponentKit
import GitKit
import GitRemote
import GitUI
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
  @Binding var selection: String?
  /// The repository on screen, whose Workspace goes under its row in `.inline`.
  let shown: String?
  let filter: String
  @State private var collapsedGroups: Set<String> = []
  @State private var isExpanded = true
  @AppStorage(VaultProjectsLayout.gitKey) private var projectsLayout = VaultProjectsLayout.separate

  private func matches(_ name: String) -> Bool { filter.isEmpty || name.localizedCaseInsensitiveContains(filter) }

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
      let tree = library.vault.projectTree.filter { ids.contains($0.id) }
      let others = remote.filter { tree.node(id: $0.id) == nil }
      if !tree.projects().isEmpty {
        VaultProjectsSection(
          tree.filter { matches($0.name) }, selection: projectSelection, key: "remoteProjects",
          collapsedGroups: $collapsedGroups
        ) {
          ProjectsLayoutMenu()
        }
        .title("On Your Devices")
        // Folded with the Repositories list, and a search still shows what it finds.
        .isExpanded(.init(get: { isExpanded || (projectsLayout == .folding && !filter.isEmpty) }, set: { isExpanded = $0 }))
        .rowContent(projectsLayout == .inline) { project in inlineWorkspace(remote.first { $0.id == project.id }) }
        .rowSubtitle { project in remote.first { $0.id == project.id }.map(subtitle) }
        .trailing { project in
          if let repository = remote.first(where: { $0.id == project.id }) { marks(repository) }
        }
        .onChange(of: selection, initial: true) { _, new in
          if projectsLayout == .folding, new != nil { isExpanded = false }
        }
        .onChange(of: projectsLayout) { _, new in isExpanded = !(new == .folding && selection != nil) }
      }
      if !others.isEmpty {
        KitSection(
          tree.projects().isEmpty ? "On Your Devices" : "On Other Machines",
          meta: [others.count == 1 ? "1 repository" : "\(others.count) repositories"], systemImage: "desktopcomputer",
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
            .kitHelp(repository.name, meta: repository.targets.first.map { "\($0.directory) on \($0.name)" })
            inlineWorkspace(repository)
          }
        }
        .kitSticky(top: .titleWhileVisible, bottom: .none)
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

/// A repository on another device until its session is in: connecting, or why it couldn't, with Try Again; under
/// either, how its device last saw it (the vault's status: branch, counts, the first files).
struct RemoteConnectionScreen: View {
  @Environment(RepositoryLibrary.self) private var library
  let key: String

  var body: some View {
    let repository = library.remoteRepository(key)
    let name = repository?.name ?? "Repository"
    let lastSeen = repository?.lastSeen
    ZStack {
      switch library.remoteStates[key] {
      case .failed(let message)?:
        EmptyState(systemImage: "exclamationmark.triangle", title: "Couldn’t Open \(name)", message: message) {
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
          systemImage: "desktopcomputer", title: name,
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
