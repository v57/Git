import Foundation
import GitKit
import GitRemote
import Observation
import VaultKit

/// What the groups of On Your Devices do on this device: fetch, pull and push on their repositories, a few at a time
/// over connections of their own, and which repositories Hide Group and Remove Group from List leave out.
@MainActor @Observable final class RemoteGroups {
  private(set) var activity: [RemoteRepository.ID: RemoteAction] = [:]
  private var checked: [RemoteRepository.ID: RepositorySummary] = [:]
  var failure: RemoteFailure?
  private(set) var hidden = RemoteGroups.savedIDs("HiddenRemoteRepositories") {
    didSet { UserDefaults.standard.set(Array(hidden), forKey: "HiddenRemoteRepositories") }
  }
  private(set) var removed = RemoteGroups.savedIDs("RemovedRemoteRepositories") {
    didSet { UserDefaults.standard.set(Array(removed), forKey: "RemovedRemoteRepositories") }
  }

  private static func savedIDs(_ key: String) -> Set<String> {
    Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
  }

  /// How it was when this device last ran something there, else as its device last said.
  func summary(of repository: RemoteRepository) -> RepositorySummary? {
    checked[repository.id] ?? repository.lastSeen?.status.summary
  }

  func setHidden(_ ids: [String], _ isHidden: Bool) {
    if isHidden { hidden.formUnion(ids) } else { hidden.subtract(ids) }
  }

  /// Takes repositories out of this device's list until `restore`; they stay on their devices and in the vault.
  func remove(_ ids: [String]) {
    removed.formUnion(ids)
    hidden.subtract(ids)
  }

  func restore(_ ids: [String]) { removed.subtract(ids) }

  func run(_ action: RemoteAction, on repositories: [RemoteRepository]) async {
    let repositories = repositories.filter { activity[$0.id] == nil }
    for repository in repositories { activity[repository.id] = action }
    var failures: [(name: String, message: String)] = []
    await withTaskGroup(of: (RemoteRepository, Result<RepositorySummary?, Error>).self) { group in
      var pending = repositories[...]
      func addNext() {
        guard let repository = pending.popFirst() else { return }
        group.addTask {
          do {
            return (repository, .success(try await RemoteRepositories.run(action, on: repository)))
          } catch {
            return (repository, .failure(error))
          }
        }
      }
      for _ in 0..<4 { addNext() }
      for await (repository, result) in group {
        activity[repository.id] = nil
        switch result {
        case .success(let summary): if let summary { checked[repository.id] = summary }
        case .failure(let error): failures.append((repository.name, RemoteRepositories.describe(error)))
        }
        addNext()
      }
    }
    if let failure = RemoteFailure(action, failures: failures) { self.failure = failure }
  }
}
