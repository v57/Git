import ComponentKit
import GitHubKit
import GitKit
import SwiftData
import SwiftUI
import UpdateKit
import VaultKit

@main
struct GitApp: App {
  @State private var library = RepositoryLibrary()
  @State private var github = GitHubAccount.app
  @AppStorage(SettingsKeys.gitPath) private var gitPath = ""

  /// Updates from GitHub Releases (Git.zip, built by Dev's release tool from release.env): checked
  /// daily once the user turns on automatic checks (never before), installed in place with a relaunch.
  private let updater = AppUpdater(github: "v57/Git", assetName: "Git.zip")

  init() {
    updater.start()
    #if DEBUG
      let syncs = !ProcessInfo.processInfo.arguments.contains("--in-memory")
    #else
      let syncs = true
    #endif
    // The repository list syncs with the other v57 apps and devices through the vault.
    if syncs { Vault.shared.startSync() }
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
        .environment(github)
        .onChange(of: gitPath) { _, path in GitExecutable.customPath = path }
        .componentKit(accent: .accentColor)
    }
    .defaultSize(width: 1440, height: 900)
    .defaultLaunchBehavior(Self.showsWelcomeAtLaunch ? .suppressed : .presented)
    .modelContainer(Self.modelContainer)
    .commands {
      RepositoryCommands(library: library)
      UpdaterCommands(updater: updater)
    }

    Window("Welcome to Git", id: WelcomeWindow.id) {
      WelcomeWindow()
        .environment(library)
        .environment(github)
        .componentKit(accent: .accentColor)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentSize)
    .defaultPosition(.center)
    .defaultLaunchBehavior(Self.showsWelcomeAtLaunch ? .presented : .suppressed)
    .modelContainer(Self.modelContainer)

    Settings {
      SettingsView()
        .environment(github)
        .componentKit(accent: .accentColor)
    }
  }
}
