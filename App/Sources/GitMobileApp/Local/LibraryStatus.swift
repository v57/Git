import Foundation
import GitEngine
import GitKit
import GitRemote
import Observation

/// What the repository list knows without opening anything: how each repository was when its screen last read it
/// (since launch; nothing is read for the list's sake), the fetches, pulls and pushes running now, and the ones Fetch
/// All couldn't do. The open repository's `RepositoryModel` writes here; the list's rows and its activity card read.
@MainActor @Observable final class LibraryStatus {
  static let shared = LibraryStatus()

  /// A fetch, pull or push under way, with git's latest progress line.
  struct Sync: Equatable {
    var action: RemoteAction
    var name: String
    var progress: String?
  }

  /// One Fetch All couldn't fetch, until its line is tapped.
  struct Failed: Equatable {
    var name: String
    var message: String
  }

  private(set) var summaries: [RepositorySource.ID: RepositorySummary] = [:]
  private(set) var syncs: [RepositorySource.ID: Sync] = [:]
  private(set) var failed: [RepositorySource.ID: Failed] = [:]
  /// Fetch All is going through the repositories on this device.
  private(set) var isFetchingAll = false

  func note(_ status: WorkingTreeStatus, of id: RepositorySource.ID) {
    let summary = RepositorySummary(status)
    if summaries[id] != summary { summaries[id] = summary }
  }

  /// Whether it may start: not while the same repository already runs one.
  func begin(_ action: RemoteAction, id: RepositorySource.ID, name: String) -> Bool {
    guard syncs[id] == nil else { return false }
    syncs[id] = Sync(action: action, name: name)
    failed[id] = nil
    return true
  }

  func progress(_ line: String, of id: RepositorySource.ID) {
    // A line that arrives after the end stays out.
    if syncs[id] != nil, syncs[id]?.progress != line { syncs[id]?.progress = line }
  }

  func end(_ id: RepositorySource.ID) { syncs[id] = nil }

  func dismissFailures(_ ids: [RepositorySource.ID]) {
    for id in ids { failed[id] = nil }
  }

  /// Fetches the repositories on this device that have a remote, one at a time (`LocalBackend.fetch`, as their
  /// screens do, at the security level's rules). The ones that fail stay as a line in the list's card.
  func fetchAll(_ repositories: [LocalRepository]) async {
    guard !isFetchingAll else { return }
    isFetchingAll = true
    defer { isFetchingAll = false }
    for repository in repositories {
      let backend = LocalBackend(repository: repository)
      let id = RepositorySource.local(repository).id
      guard await !backend.remoteURLs().isEmpty, begin(.fetch, id: id, name: repository.name) else { continue }
      do {
        try await backend.fetch { line in
          Task { @MainActor in self.progress(line, of: id) }
        }
        if let status = try? await backend.status() { note(status, of: id) }
      } catch {
        failed[id] = Failed(name: repository.name, message: RepositoryModel.describe(error))
      }
      end(id)
    }
  }
}
