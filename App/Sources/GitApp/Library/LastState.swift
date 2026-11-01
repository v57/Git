import Foundation
import GitKit

/// What Git showed when it last ran, so a relaunch starts with it while it looks again: every repository's sidebar
/// summary and dates, and the changes of the repositories that were open (`RepositorySession.Snapshot`). The values
/// rarely change between launches, and the first refresh replaces whatever did. One JSON file in the app's caches,
/// shared by the windows; `--in-memory` launches neither read nor write it, unless a debug build is given a file of
/// their own (`GIT_DEBUG_LAST_STATE=<path>`, to check a relaunch).
@MainActor final class LastState {
  static let shared = LastState()

  struct Contents: Codable {
    var summaries: [String: RepositorySummary] = [:]
    var activities: [String: RepositoryActivity] = [:]
    var sessions: [String: RepositorySession.Snapshot] = [:]
  }

  private(set) var contents: Contents
  private var saving: Task<Void, Never>?

  /// Snapshots with more changes than this aren't kept (a folder of build output nobody ignored): the file stays small.
  private static let changeLimit = 2000

  /// A debug launch's own file, which `--in-memory` launches use too.
  static let debugFile: URL? = {
    #if DEBUG
      ProcessInfo.processInfo.environment["GIT_DEBUG_LAST_STATE"].map { URL(fileURLWithPath: $0) }
    #else
      nil
    #endif
  }()

  private static let file: URL = {
    if let debugFile { return debugFile }
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return caches.appendingPathComponent("dev.v57.git", isDirectory: true).appendingPathComponent("last-state.json")
  }()

  private init() {
    let data = try? Data(contentsOf: Self.file)
    contents = data.flatMap { try? JSONDecoder().decode(Contents.self, from: $0) } ?? Contents()
  }

  /// Keeps the sidebar's values and the loaded sessions' state, written a moment later (a refresh of many
  /// repositories saves once). A repository gone from `summaries` is forgotten.
  func remember(
    summaries: [String: RepositorySummary], activities: [String: RepositoryActivity],
    sessions: [String: RepositorySession]
  ) {
    contents.summaries.merge(summaries) { $1 }
    contents.activities.merge(activities) { $1 }
    for (key, session) in sessions {
      guard let snapshot = session.snapshot else { continue }
      let status = snapshot.status
      if status.staged.count + status.unstaged.count + status.conflicted.count > Self.changeLimit {
        contents.sessions[key] = nil
      } else {
        contents.sessions[key] = snapshot
      }
    }
    scheduleSave()
  }

  /// Forgets removed repositories.
  func forget(_ keys: [String]) {
    for key in keys {
      contents.summaries[key] = nil
      contents.activities[key] = nil
      contents.sessions[key] = nil
    }
    scheduleSave()
  }

  private func scheduleSave() {
    saving?.cancel()
    saving = Task {
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      let contents = contents
      await Task.detached(priority: .utility) {
        guard let data = try? JSONEncoder().encode(contents) else { return }
        try? FileManager.default.createDirectory(
          at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
      }.value
    }
  }
}
