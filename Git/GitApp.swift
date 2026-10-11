import GitKit
import SwiftData
import SwiftUI

@main
struct GitApp: App {
  @State private var library = RepositoryLibrary()
  @AppStorage(SettingsKeys.gitPath) private var gitPath = ""

  init() {
    GitExecutable.customPath = UserDefaults.standard.string(forKey: SettingsKeys.gitPath)
    #if DEBUG
      // --light draws the app in light mode, for screenshots.
      if ProcessInfo.processInfo.arguments.contains("--light") {
        DispatchQueue.main.async { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
      }
    #endif
  }

  /// The saved repositories, in `RepositoryStore.url` (or in memory with `--in-memory`).
  private static let modelContainer = RepositoryStore.makeContainer()

  /// Whether the Welcome window opens at launch instead of the main window. Debug launches that
  /// add folders go straight to the main window unless `--welcome` is passed.
  private static let showsWelcomeAtLaunch: Bool = {
    let arguments = ProcessInfo.processInfo.arguments
    #if DEBUG
      if arguments.contains("--welcome") { return true }
      if arguments.contains("--add-folder") { return false }
    #endif
    return UserDefaults.standard.object(forKey: WelcomeWindow.showAtLaunchKey) as? Bool ?? true
  }()

  var body: some Scene {
    WindowGroup("Git", id: MainWindow.id) {
      ContentView()
        .environment(library)
        .onChange(of: gitPath) { _, path in GitExecutable.customPath = path }
    }
    .defaultSize(width: 1440, height: 900)
    .defaultLaunchBehavior(Self.showsWelcomeAtLaunch ? .suppressed : .presented)
    .modelContainer(Self.modelContainer)
    .commands {
      RepositoryCommands(library: library)
    }

    Window("Welcome to Git", id: WelcomeWindow.id) {
      WelcomeWindow()
        .environment(library)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentSize)
    .defaultPosition(.center)
    .defaultLaunchBehavior(Self.showsWelcomeAtLaunch ? .presented : .suppressed)
    .modelContainer(Self.modelContainer)

    Settings {
      SettingsView()
    }
  }
}
