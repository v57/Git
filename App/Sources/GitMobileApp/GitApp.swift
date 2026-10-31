import ComponentKit
import GitEngine
import GitHubKit
import GitUI
import SwiftUI
import VaultKit

/// Git on iPhone and iPad. Repositories on this device (in the app's folder, which the Files app shows) are read and
/// written by GitEngine, git in Swift: clone, changes, commit, branches, pull and push. Repositories on the user's
/// Macs (the vault's projects on devices of their Hub, or folders on any SSH host saved in the Vault app) run the
/// Mac's own git over SSH through GitKit, so everything the Mac app does with changes works there.
public struct GitApp: App {
  public init() {}

  public var body: some Scene {
    WindowGroup {
      RepositoriesView()
        .environment(GitHubAccount.app)
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
  @Environment(\.kitIdiom) private var idiom
  @Environment(\.scenePhase) private var scenePhase

  private var remote: [RemoteRepository] {
    _ = savedRevision
    return RemoteRepositories.all(vault: vault)
  }

  private var sources: [RepositorySource] {
    local.repositories.map(RepositorySource.local) + remote.map(RepositorySource.remote)
  }

  var body: some View {
    root
      .kitSheet(item: $sheet) { sheet in
        switch sheet {
        case .clone: CloneSheet { selection = RepositorySource.local($0).id }
        case .create: NewRepositorySheet { selection = RepositorySource.local($0).id }
        case .addRemote:
          AddRemoteSheet { saved in
            savedRevision += 1
            selection = "remote:saved:" + saved.id
          }
        case .settings: SettingsSheet()
        }
      }
      .onChange(of: scenePhase) { _, phase in
        // Folders added in the Files app meanwhile.
        if phase == .active { local.reload() }
      }
  }

  @ViewBuilder private var root: some View {
    Group {
      if idiom == .phone { stack } else { split }
    }
    .task {
      #if DEBUG
        if let id = await DebugLaunch.selected(in: sources) { selection = id }
        if let sheet = DebugLaunch.sheet { self.sheet = sheet }
      #endif
    }
  }

  private var sidebar: some View {
    RepositoriesSidebar(
      local: local.repositories, remote: remote, selection: $selection, columnVisibility: $columnVisibility,
      sheet: $sheet
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
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
    } detail: {
      NavigationStack {
        if let source = sources.first(where: { $0.id == selection }) {
          RepositoryScreen(source: source).id(source.id)
        } else {
          RepositoriesWelcome(sources: sources, selection: $selection, sheet: $sheet)
        }
      }
      .kitSidebarToggle(columnVisibility: $columnVisibility)
    }
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
      WelcomeAction("Clone Repository…", detail: "From GitHub or any HTTPS URL", systemImage: "square.and.arrow.down") {
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
          RecentItem(repository.name, subtitle: "On this device", systemImage: "internaldrive") {
            selection = source.id
          }
        case .remote(let repository):
          RecentItem(
            repository.name, subtitle: repository.targets.map(\.name).joined(separator: ", "),
            systemImage: repository.icon == nil ? "desktopcomputer" : nil,
            image: repository.icon.flatMap(Image.init(data:))
          ) { selection = source.id }
        }
      }
    }
    .listTitle("Repositories")
    .kitPane(.content)
  }
}

/// The repositories as the kit's sidebar: a card for those on this device and one for those on the user's other
/// devices; search filters both, and the bar says how many devices Git reaches.
struct RepositoriesSidebar: View {
  let local: [LocalRepository]
  let remote: [RemoteRepository]
  @Binding var selection: RepositorySource.ID?
  @Binding var columnVisibility: NavigationSplitViewVisibility
  @Binding var sheet: LibrarySheet?
  let remove: (RepositorySource) -> Void
  @State private var search = ""
  @State private var pendingRemoval: RepositorySource?
  @State private var showsAddMenu = false
  @Environment(\.kitIdiom) private var idiom

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
        meta: [local.count == 1 ? "1 repository" : "\(local.count) repositories"], systemImage: "internaldrive",
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
      KitSection(
        "On Your Devices",
        meta: [remote.count == 1 ? "1 repository" : "\(remote.count) repositories"], systemImage: "desktopcomputer",
        hue: .blue
      ) {
        ForEach(remote.filter { matches($0.name) }) { repository in
          let source = RepositorySource.remote(repository)
          SidebarRow(value: source.id, repository.name, subtitle: subtitle(repository)) {
            if let icon = repository.icon.flatMap(Image.init(data:)) {
              Avatar(name: repository.name, image: icon, kind: .thing, size: 32)
            } else {
              Avatar(name: repository.name, kind: .thing, size: 32)
            }
          } trailing: {
            chevron
          }
          .kitContextMenu {
            if repository.id.hasPrefix("saved:") {
              Button("Remove from List", systemImage: "minus.circle") { remove(source) }
            }
          }
        }
        if remote.isEmpty {
          Text("Projects on the devices of your Hub appear here. Open a folder on any SSH host with Open on a Mac.")
            .kitFont(.caption).foregroundStyle(.kitSecondary).padding(10)
        }
      } accessory: {
        Button("Open on a Mac", systemImage: "plus") { sheet = .addRemote }
          .labelStyle(.iconOnly)
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
    .kitConfirmation(
      "Delete \(pendingRemoval?.name ?? "")?",
      isPresented: .init(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
      message: "Its folder is deleted from this device, with commits that were never pushed.", systemImage: "trash",
      confirm: "Delete"
    ) {
      if let source = pendingRemoval { remove(source) }
    }
  }

  /// The devices it is on, as Code lists its projects: "via Hub" after each repeated itself on every row.
  private func subtitle(_ repository: RemoteRepository) -> String {
    repository.targets.map(\.name).joined(separator: ", ")
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
