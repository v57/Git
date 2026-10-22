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
      // --light and --dark draw the app in that appearance, for screenshots.
      #if os(macOS)
        if ProcessInfo.processInfo.arguments.contains("--light") {
          DispatchQueue.main.async { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
        } else if ProcessInfo.processInfo.arguments.contains("--dark") {
          DispatchQueue.main.async { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        }
      #endif
    #endif
  }

  /// The saved repositories, in `RepositoryStore.url` (or in memory with `--in-memory`).
  private static let modelContainer = RepositoryStore.makeContainer()

  /// Screenshot captures build every row at once, so nothing waits to be built as it's taken.
  private static let buildsLazily: Bool = {
    #if DEBUG
      ProcessInfo.processInfo.environment["DEV_SCREENSHOT"] == nil
    #else
      true
    #endif
  }()

  var body: some Scene {
    WindowGroup("Git", id: MainWindow.id) {
      ContentView()
        .environment(library)
        .environment(github)
        .onChange(of: gitPath) { _, path in GitExecutable.customPath = path }
        .kitLazyLoading(Self.buildsLazily)
        .componentKit(accent: .accentColor)
    }
    .defaultSize(width: 1440, height: 900)
    .modelContainer(Self.modelContainer)
    .commands {
      RepositoryCommands(library: library)
      UpdaterCommands(updater: updater)
    }

    Settings {
      SettingsView()
        .environment(github)
        .componentKit(accent: .accentColor)
    }
  }
}
