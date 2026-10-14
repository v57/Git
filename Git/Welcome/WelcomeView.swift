import AppKit
import GitKit
import SwiftData
import SwiftUI

/// The Welcome window, shown at launch: clone, open or create a repository on the left, recent
/// repositories with their state on the right.
struct WelcomeWindow: View {
  static let id = "welcome"
  static let showAtLaunchKey = "ShowWelcomeAtLaunch"
  /// The safe-area inset of a hidden title bar.
  private static let titleBarInset: CGFloat = 32

  @Environment(RepositoryLibrary.self) private var library
  @Environment(\.modelContext) private var context
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  @AppStorage(showAtLaunchKey) private var showAtLaunch = true
  @Query(sort: \SavedRepository.name) private var repositories: [SavedRepository]
  @State private var search = ""
  @State private var isDropTargeted = false

  private var recent: [SavedRepository] {
    repositories
      .filter {
        search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
          || $0.path.localizedCaseInsensitiveContains(search)
      }
      .sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
  }

  var body: some View {
    @Bindable var library = library
    // The window is 860 × 540 including the hidden title bar: the clear frame sizes the window
    // without the title bar's inset, and the content fills it, title bar area included.
    Color.clear
      .frame(width: 860, height: 540 - Self.titleBarInset)
      .overlay {
        HStack(spacing: 0) {
          identity
            .frame(width: 340)
          Divider()
          recents
            .frame(maxWidth: .infinity)
        }
        .frame(width: 860, height: 540)
        .ignoresSafeArea()
      }
    .tracking(.designTracking)
    .sheet(isPresented: $library.isClonePresented) { CloneSheet() }
    .onChange(of: library.requestedSelection) { _, path in
      if path != nil { showMainWindow() }
    }
    .task(id: sceneGeneration) {
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
  }

  /// Sets the window up again for each screenshot scene opened in place.
  private var sceneGeneration: Int {
    #if DEBUG
      LaunchScene.shared.generation
    #else
      0
    #endif
  }

  // MARK: Left

  private var identity: some View {
    VStack(spacing: 0) {
      VStack(spacing: 2) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 96, height: 96)
          .accessibilityHidden(true)
        Text("Git")
          .font(.system(size: 28, weight: .bold))
          .padding(.top, 8)
        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      .padding(.top, 56)
      .padding(.bottom, 24)
      VStack(spacing: 4) {
        WelcomeAction(
          title: "Clone Repository…", detail: "From GitHub, GitLab or any URL",
          systemImage: "icloud.and.arrow.down", shortcut: "⇧⌘C"
        ) { library.isClonePresented = true }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        WelcomeAction(
          title: "Open Local Repository…", detail: "Any folder with a .git directory",
          systemImage: "folder", shortcut: "⌘O"
        ) { openLocal() }
        .keyboardShortcut("o", modifiers: .command)
        WelcomeAction(
          title: "New Repository…", detail: "Start tracking a folder",
          systemImage: "plus", shortcut: "⌥⌘N"
        ) {
          Task {
            await library.createRepository(into: context)
          }
        }
        .keyboardShortcut("n", modifiers: [.command, .option])
      }
      .padding(.horizontal, 14)
      Spacer()
      Toggle("Show this window when Git opens", isOn: $showAtLaunch)
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 30)
        .padding(.bottom, 18)
    }
  }

  // MARK: Right

  private var recents: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Text("Recent").fontWeight(.semibold)
        Spacer()
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
          TextField("Search", text: $search)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .onAppear {
              // Keep the field from taking focus when the window opens.
              DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 200, height: 28)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 7))
      }
      .padding(.horizontal, 20)
      .padding(.top, 20)
      .padding(.bottom, 10)
      ScrollView {
        VStack(spacing: 2) {
          ForEach(Array(recent.enumerated()), id: \.element.id) { index, repository in
            RecentRow(
              repository: repository, summary: library.summaries[repository.path],
              isFirst: index == 0 && search.isEmpty
            ) {
              library.requestedSelection = repository.path
            }
          }
        }
        .padding(.horizontal, 14)
        .animation(.app, value: recent.map(\.path))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay {
        if repositories.isEmpty {
          Text("Repositories you open appear here.")
            .foregroundStyle(.secondary)
            .fixedSize()
        }
      }
      HStack(spacing: 8) {
        Image(systemName: "arrow.down.to.line")
        Text("Drop a folder here to open it")
      }
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity)
      .frame(height: 56)
      .animation(.app, value: isDropTargeted)
      .background(
        isDropTargeted ? Color.accentColor.opacity(0.08) : .clear,
        in: .rect(cornerRadius: 12, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(
            isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
      )
      .padding(14)
    }
    .background(Color.primary.opacity(0.03))
    .dropDestination(for: URL.self) { urls, _ in
      Task {
        if let first = await library.importFolders(urls, into: context).first {
          library.requestedSelection = first
        }
      }
      return true
    } isTargeted: { isDropTargeted = $0 }
  }

  // MARK: Actions

  private func openLocal() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.prompt = "Open"
    guard panel.runModal() == .OK else { return }
    let urls = panel.urls
    Task {
      let added = await library.importFolders(urls, into: context)
      if let path = added.first ?? urls.first.map({ $0.standardizedFileURL.path }) {
        library.requestedSelection = path
      }
    }
  }

  /// Brings up the main window (opening one if there is none) and closes this one.
  private func showMainWindow() {
    let main = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true }
    if let main {
      main.makeKeyAndOrderFront(nil)
    } else {
      openWindow(id: MainWindow.id)
    }
    dismissWindow(id: Self.id)
  }
}

enum MainWindow {
  static let id = "main"
}

private struct WelcomeAction: View {
  let title: String
  let detail: String
  let systemImage: String
  let shortcut: String
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: systemImage)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(Color.accentColor)
          .frame(width: 32, height: 32)
          .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
        VStack(alignment: .leading, spacing: 1) {
          Text(title).fontWeight(.semibold)
          Text(detail)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .layoutPriority(1)
        Spacer(minLength: 8)
        Text(shortcut)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize()
      }
      .padding(.horizontal, 10)
      .frame(height: 52)
      .background(
        Color.primary.opacity(isHovered ? 0.06 : 0), in: .rect(cornerRadius: 10, style: .continuous)
      )
      .contentShape(.rect(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.app, value: isHovered)
  }
}

/// A recent repository: icon, name and branch, path, state and when it was last opened.
private struct RecentRow: View {
  let repository: SavedRepository
  let summary: RepositorySummary?
  let isFirst: Bool
  let open: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: open) {
      HStack(spacing: 12) {
        RepositoryIcon(name: repository.name, size: 34)
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 8) {
            Text(repository.name).fontWeight(.semibold)
            if let branch = summary?.branchLabel {
              Text(branch)
                .font(.system(size: 11))
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Color.primary.opacity(0.07), in: .capsule)
                .lineLimit(1)
            }
          }
          Text((repository.path as NSString).abbreviatingWithTildeInPath)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        }
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 2) {
          Text(status.text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(status.color)
          Text((repository.lastOpenedAt ?? repository.addedAt).dayFormatted)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 10)
      .frame(height: 56)
      .background {
        if isFirst || isHovered {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.app, value: isHovered)
    .help(repository.path)
  }

  private var status: (text: String, color: Color) {
    guard repository.exists else { return ("Missing", .orange) }
    guard let summary else { return ("", .secondary) }
    if let operation = summary.operation { return (operation.title, .orange) }
    if summary.changeCount > 0 {
      return (summary.changeCount == 1 ? "1 change" : "\(summary.changeCount) changes", .orange)
    }
    if summary.ahead > 0 { return ("↑\(summary.ahead) to push", .blue) }
    if summary.behind > 0 { return ("↓\(summary.behind) to pull", .blue) }
    return ("Up to date", .green)
  }
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
    VStack(alignment: .leading, spacing: 0) {
      Form {
        TextField("URL", text: $remote, prompt: Text("https://github.com/owner/repository.git"))
          .onChange(of: remote) {
            if !isNameEdited { name = Self.name(from: remote) }
          }
        TextField("Name", text: .init(get: { name }, set: { name = $0; isNameEdited = true }))
        LabeledContent("Location") {
          HStack {
            Text((location as NSString).abbreviatingWithTildeInPath)
              .lineLimit(1)
              .truncationMode(.head)
            Button("Choose…", action: chooseLocation)
          }
        }
        if cloning != nil {
          LabeledContent("Progress") {
            Text(progress.line ?? "Starting…")
              .font(.caption.monospaced())
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        if let error {
          Text(error)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
      .formStyle(.grouped)
      .disabled(cloning != nil)
      HStack {
        Spacer()
        Button("Cancel") {
          cloning?.cancel()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button("Clone", action: clone)
          .keyboardShortcut(.defaultAction)
          .disabled(!canClone)
      }
      .padding([.horizontal, .bottom], 20)
    }
    .frame(width: 480)
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
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.directoryURL = URL(fileURLWithPath: location)
    panel.prompt = "Choose"
    if panel.runModal() == .OK, let url = panel.url { location = url.path }
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
