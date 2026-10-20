import ComponentKit
import GitKit
import SwiftData
import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The Welcome window, shown at launch: clone, open or create a repository on the left, recent
/// repositories with their state on the right.
struct WelcomeWindow: View {
  static let id = "welcome"
  static let showAtLaunchKey = "ShowWelcomeAtLaunch"

  @Environment(RepositoryLibrary.self) private var library
  @Environment(\.modelContext) private var context
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  @AppStorage(showAtLaunchKey) private var showAtLaunch = true
  @Query(sort: \SavedRepository.name) private var repositories: [SavedRepository]
  @State private var search = ""

  /// The repositories, last opened first, that match the search by name or folder.
  private var recent: [SavedRepository] {
    let query = search.trimmingCharacters(in: .whitespaces)
    return repositories
      .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
      .sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
  }

  /// The safe-area inset of a hidden title bar.
  private static let titleBarInset: CGFloat = 32

  var body: some View {
    @Bindable var library = library
    // The window is 480 × 640 including the hidden title bar: the clear frame sizes the window
    // without the title bar's inset, and the welcome fills it, title bar area included.
    Color.clear
      .frame(width: 480, height: 640 - Self.titleBarInset)
      .overlay {
        welcome
          .frame(height: 640)
          .ignoresSafeArea()
      }
      .sheet(isPresented: $library.isClonePresented) { CloneSheet() }
      .onChange(of: library.requestedSelection) { _, path in
        if path != nil { showMainWindow() }
      }
      .task(id: sceneGeneration) { await prepare() }
  }

  /// The kit's round close button stands in for the window's own buttons.
  private var welcome: some View {
    KitWelcome(
      appName: "Git", showAtLaunch: $showAtLaunch,
      emptyTitle: search.isEmpty ? "No Repositories" : "No Matches",
      emptyMessage: search.isEmpty ? "Repositories you open appear here." : "No repository is named “\(search)”.",
      searchText: $search, searchPrompt: "Search Repositories",
      close: { dismissWindow(id: Self.id) },
      onDrop: { urls in
        Task {
          if let first = await library.importFolders(urls, into: context).first {
            library.requestedSelection = first
          }
        }
        return true
      }
    ) {
      WelcomeAction("Clone Repository…", detail: "From GitHub, GitLab or any URL", systemImage: "arrow.down") {
        library.isClonePresented = true
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])
      WelcomeAction("Open Local Repository…", detail: "Any folder with a .git directory", systemImage: "folder") {
        openLocal()
      }
      .keyboardShortcut("o", modifiers: .command)
      WelcomeAction("New Repository…", detail: "Start tracking a folder", systemImage: "plus") {
        Task { await library.createRepository(into: context) }
      }
      .keyboardShortcut("n", modifiers: [.command, .option])
    } recents: {
      ForEach(recent) { repository in
        let status = Self.status(repository, summary: library.summaries[repository.path])
        RecentItem(
          repository.name, subtitle: (repository.path as NSString).abbreviatingWithTildeInPath,
          date: (repository.lastOpenedAt ?? repository.addedAt).dayFormatted, status: status?.text,
          statusHue: status?.hue ?? .gray, id: repository.path
        ) {
          library.requestedSelection = repository.path
        }
      }
    }
  }

  private func prepare() async {
    library.vaultProjects.start(context: context, library: library)
    #if DEBUG
      // --add-folder works here too, so the Recent list can be filled for screenshots.
      let scene = LaunchScene.shared
      scene.prepare(library: library, context: context)
      // A later screenshot scene in the main window, which adds its repositories.
      if !scene.flag("--welcome"), sceneGeneration > 0 {
        showMainWindow()
        return
      }
      let saved = (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []
      if !scene.folders.isEmpty, saved.isEmpty {
        await library.importFolders(scene.folders, into: context)
      }
    #endif
    let paths = ((try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []).map(\.path)
    await library.refreshSummaries(paths)
    #if DEBUG
      LaunchScene.shared.loaded(welcome: true)
    #endif
  }

  /// A repository's state as a chip: the operation in progress, its changes, what to push or
  /// pull, or up to date.
  private static func status(_ repository: SavedRepository, summary: RepositorySummary?) -> (text: String, hue: Hue)? {
    guard repository.exists else { return ("Missing", .orange) }
    guard let summary else { return nil }
    if let operation = summary.operation { return (operation.title, .orange) }
    if summary.changeCount > 0 {
      return (summary.changeCount == 1 ? "1 change" : "\(summary.changeCount) changes", .orange)
    }
    if summary.ahead > 0 { return ("\(summary.ahead) to push", .orange) }
    if summary.behind > 0 { return ("\(summary.behind) to pull", .blue) }
    return ("Up to date", .green)
  }

  /// Sets the window up again for each screenshot scene opened in place.
  private var sceneGeneration: Int {
    #if DEBUG
      LaunchScene.shared.generation
    #else
      0
    #endif
  }

  // MARK: Actions

  private func openLocal() {
    Task {
      let urls = await KitDesktop.chooseFolders(prompt: "Open", allowsMultipleSelection: true)
      guard !urls.isEmpty else { return }
      let added = await library.importFolders(urls, into: context)
      if let path = added.first ?? urls.first.map({ $0.standardizedFileURL.path }) {
        library.requestedSelection = path
      }
    }
  }

  /// Brings up the main window (opening one if there is none) and closes this one.
  private func showMainWindow() {
    #if os(macOS)
      let main = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true }
      if let main {
        main.makeKeyAndOrderFront(nil)
      } else {
        openWindow(id: MainWindow.id)
      }
    #else
      openWindow(id: MainWindow.id)
    #endif
    dismissWindow(id: Self.id)
  }
}

enum MainWindow {
  static let id = "main"
}

/// Clones a repository into a folder and adds it to the sidebar.
struct CloneSheet: View {
  @Environment(RepositoryLibrary.self) private var library
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss
  @AppStorage("CloneLocation") private var location = Self.defaultLocation
  @State private var remote = ""
  @State private var name = ""
  @State private var isNameEdited = false
  @State private var progress = CloneProgress()
  @State private var error: String?
  @State private var cloning: Task<Void, Never>?

  private static var defaultLocation: String {
    let developer = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Developer")
    return FileManager.default.fileExists(atPath: developer.path)
      ? developer.path : FileManager.default.homeDirectoryForCurrentUser.path
  }

  private var destination: URL {
    URL(fileURLWithPath: location, isDirectory: true).appendingPathComponent(name, isDirectory: true)
  }

  private var canClone: Bool {
    !remote.trimmingCharacters(in: .whitespaces).isEmpty && !name.isEmpty && !name.contains("/")
      && cloning == nil
  }

  var body: some View {
    KitSheet(
      title: "Clone Repository", meta: "Copies a repository from GitHub, GitLab or any URL.",
      systemImage: "arrow.down", status: cloning == nil ? .idle : cloneStatus, width: 480
    ) {
      FormCard {
        FormRow(
          "Repository URL", help: "GitHub, GitLab or any Git URL", systemImage: "link",
          field: TextField("https://github.com/owner/repository.git", text: $remote)
            .onChange(of: remote) {
              if !isNameEdited { name = Self.name(from: remote) }
            })
        FormRow(
          "Name", systemImage: "character.cursor.ibeam",
          error: name.contains("/") ? "A name can't contain “/”" : nil,
          field: TextField("repository", text: .init(get: { name }, set: { name = $0; isNameEdited = true })))
        FormRow("Location", help: (location as NSString).abbreviatingWithTildeInPath, systemImage: "folder", hue: .teal) {
          Button("Choose…", action: chooseLocation).buttonStyle(.kit)
        }
      }
      .disabled(cloning != nil)
    } footer: {
      if cloning != nil {
        SheetStatus(progress.line ?? "Starting…", systemImage: "arrow.down", status: cloneStatus)
      } else if let error {
        SheetStatus(error, systemImage: "exclamationmark.triangle", hue: .red, status: .failed)
      }
      Spacer(minLength: 0)
      Button("Cancel") {
        cloning?.cancel()
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      Button("Clone", action: clone)
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(!canClone)
    }
  }

  /// Working, with the share received once git reports it.
  private var cloneStatus: WorkStatus {
    .working(progress: progress.line.flatMap(GitProgress.fraction))
  }

  /// `https://host/owner/repo.git` or `git@host:owner/repo.git` → `repo`.
  static func name(from remote: String) -> String {
    var last = remote.trimmingCharacters(in: .whitespaces)
    while last.hasSuffix("/") { last.removeLast() }
    last = String(last.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
    if last.hasSuffix(".git") { last.removeLast(4) }
    return last
  }

  private func chooseLocation() {
    Task {
      let chosen = await KitDesktop.chooseFolders(
        prompt: "Choose", directory: URL(fileURLWithPath: location), canCreateDirectories: true)
      if let url = chosen.first { location = url.path }
    }
  }

  private func clone() {
    let destination = destination
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      error = "\(destination.lastPathComponent) already exists in this location."
      return
    }
    let remote = remote.trimmingCharacters(in: .whitespaces)
    let progress = progress
    error = nil
    cloning = Task {
      defer { cloning = nil }
      do {
        try await Repository.clone(remote, to: destination) { line in
          Task { @MainActor in progress.line = line }
        }
        library.open(destination, into: context)
        dismiss()
      } catch {
        self.error = (error as? GitError)?.message ?? error.localizedDescription
      }
    }
  }
}

@MainActor @Observable private final class CloneProgress {
  var line: String?
}
