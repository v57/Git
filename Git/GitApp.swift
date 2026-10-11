import GitKit
import SwiftData
import SwiftUI

@main
struct GitApp: App {
  @State private var library = RepositoryLibrary()
  @AppStorage(SettingsKeys.gitPath) private var gitPath = ""

  init() {
    GitExecutable.customPath = UserDefaults.standard.string(forKey: SettingsKeys.gitPath)
  }

  /// The saved repositories, in `RepositoryStore.url` (or in memory with `--in-memory`).
  private static let modelContainer = RepositoryStore.makeContainer()

  var body: some Scene {
    WindowGroup("Git") {
      ContentView()
        .environment(library)
        .onChange(of: gitPath) { _, path in GitExecutable.customPath = path }
    }
    .defaultSize(width: 1280, height: 800)
    .modelContainer(Self.modelContainer)
    .commands {
      RepositoryCommands(library: library)
    }

    Settings {
      SettingsView()
    }
  }
}
