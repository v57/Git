#if DEBUG
  import DevScreenshots
  import SwiftData
  import SwiftUI

  /// The debug launch arguments that set up a screen (`--add-folder`, `--mode`, `--select-commit`, `--welcome`, …),
  /// for screenshots and scripted runs. Dev's `dev-screenshots` takes the scenes of `.dev/screenshots.json` in one
  /// launch: the first comes as the launch's arguments, every later one replaces them here, after the repositories
  /// of the scene before are gone, so the windows open it as they would at a launch.
  @MainActor @Observable final class LaunchScene {
    static let shared = LaunchScene()

    /// The scene's arguments: the launch's own, then each later scene's.
    private(set) var arguments = ProcessInfo.processInfo.arguments
    /// Counts the scenes opened in place, so the windows set themselves up again.
    private(set) var generation = 0
    /// The scene being opened in place, until it has loaded.
    @ObservationIgnored private var opening: CheckedContinuation<Void, Never>?

    func value(_ name: String) -> String? {
      arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    func flag(_ name: String) -> Bool { arguments.contains(name) }

    /// `--add-folder <path>`, repeatable.
    var folders: [URL] {
      arguments.indices.dropLast().filter { arguments[$0] == "--add-folder" }
        .map { URL(fileURLWithPath: arguments[$0 + 1]) }
    }

    /// Whether `path` is one of the scene's repositories, not one a window restored or a scene before left.
    func includes(_ path: String) -> Bool {
      folders.contains { path == $0.standardizedFileURL.path || path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// Joins a screenshot capture, if this launch is one. Called by whichever window comes first.
    func prepare(library: RepositoryLibrary, context: ModelContext) {
      Screenshots.prepare(waitsForReady: true) { scene in
        await self.open(scene.arguments, library: library, context: context)
      }
    }

    /// A later scene: back to an empty list as at launch, then the windows open the scene from its arguments.
    /// Returns once it has loaded.
    private func open(_ arguments: [String], library: RepositoryLibrary, context: ModelContext) async {
      let repositories = (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []
      library.remove(repositories, from: context)
      self.arguments = arguments
      generation += 1
      await withCheckedContinuation { opening = $0 }
    }

    /// The scene has loaded in its window: the main window (`welcome` false) or the Welcome window. The other
    /// window's word doesn't count.
    func loaded(welcome: Bool) {
      guard flag("--welcome") == welcome else { return }
      if let opening {
        self.opening = nil
        opening.resume()
      } else {
        Screenshots.ready()
      }
    }
  }
#endif
