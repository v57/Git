import Foundation
import GitEngine
import GitKit
import GitRemote

extension AutoFetch {
  /// Whether a repository with a remote may be fetched now.
  func isDue(_ backend: any GitBackend, key: String, isOtherDevice: Bool) async -> Bool {
    let urls = await backend.remoteURLs()
    guard !urls.isEmpty else { return false }
    return isDue(key, lastFetched: await backend.lastFetchDate(), remoteURLs: urls, isOtherDevice: isOtherDevice)
  }

  /// The repositories on this device that are due, one at a time. Those on other devices wait to be opened: startup
  /// doesn't sign in to every device.
  func fetchAtStartup(_ repositories: [LocalRepository]) async {
    guard runsAtStartup else { return }
    for repository in repositories {
      let backend = LocalBackend(repository: repository)
      let key = RepositorySource.local(repository).id
      guard await isDue(backend, key: key, isOtherDevice: false) else { continue }
      noteAttempt(key)
      try? await backend.fetch { _ in }
    }
  }
}
