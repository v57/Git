import Foundation
import GitKit
import GitRemote
import SwiftData
import VaultKit

/// Settings ▸ Privacy's auto-fetch on the Mac. Off, none of this reaches the network. A fetch it starts goes through
/// `run`, as the sidebar's does, without telling the user when one fails: nobody asked for it.
extension RepositoryLibrary {
  /// The accounts whose repositories were looked at since launch: another window on the same account changes nothing.
  private static var fetchedAtStartup: Set<String> = []

  /// The repositories on this Mac with a remote that are due. Those on other devices wait to be selected: startup
  /// doesn't sign in to every device.
  func autoFetchAtStartup(context: ModelContext) async {
    let auto = AutoFetch.shared
    guard auto.runsAtStartup, Self.fetchedAtStartup.insert(vault.accountID).inserted else { return }
    var due: [String] = []
    for path in layout(context).repositories().map(\.path) {
      let repository = Repository(url: URL(fileURLWithPath: path, isDirectory: true), runner: runner(for: path))
      let urls = await remoteURLs(of: repository)
      guard !urls.isEmpty else { continue }
      if auto.isDue(path, lastFetched: await repository.lastFetchDate(), remoteURLs: urls) { due.append(path) }
    }
    await autoFetch(due)
  }

  /// The repository just selected, once its session has loaded, if it's due.
  func autoFetchSelected(_ key: String) async {
    let auto = AutoFetch.shared
    guard auto.runsOnSelection, let session = loadedSession(for: key), !session.remotes.isEmpty, !session.isBusy
    else { return }
    let isOtherDevice = Self.isRemote(key)
    let urls = isOtherDevice ? [] : await remoteURLs(of: session.repository)
    guard auto.isDue(key, lastFetched: session.lastFetched, remoteURLs: urls, isOtherDevice: isOtherDevice) else { return }
    await autoFetch([key])
  }

  private func remoteURLs(of repository: Repository) async -> [String] {
    var urls: [String] = []
    for remote in (try? await repository.remotes()) ?? [] {
      if let url = try? await repository.remoteURL(remote) { urls.append(url) }
    }
    return urls
  }

  private func autoFetch(_ keys: [String]) async {
    guard !keys.isEmpty else { return }
    keys.forEach(AutoFetch.shared.noteAttempt)
    await run(.fetch, on: keys, quiet: true)
  }
}
