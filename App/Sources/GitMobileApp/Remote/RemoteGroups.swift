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

  /// Whether this device read it itself since launch (a group action or a refresh), rather than showing what its
  /// device last wrote to the vault.
  func isChecked(_ repository: RemoteRepository) -> Bool { checked[repository.id] != nil }

  /// The list's pull to refresh (G-008): reads how each repository is now on its device, over SSH and without
  /// fetching, a few at a time. Where a device doesn't answer, its row keeps the vault's status with its age, and a
  /// notice says which couldn't be read.
  func refresh(_ repositories: [RemoteRepository]) async {
    let repositories = repositories.filter { activity[$0.id] == nil }
    guard !repositories.isEmpty else { return }
    var failures: [(name: String, message: String)] = []
    await withTaskGroup(of: (RemoteRepository, Result<RepositorySummary, Error>).self) { group in
      var pending = repositories[...]
      func addNext() {
        guard let repository = pending.popFirst() else { return }
        group.addTask {
          do {
            return (repository, .success(try await RemoteRepositories.status(of: repository)))
          } catch {
            return (repository, .failure(error))
          }
        }
      }
      for _ in 0..<4 { addNext() }
      for await (repository, result) in group {
        switch result {
        case .success(let summary): checked[repository.id] = summary
        case .failure(let error): failures.append((repository.name, RemoteRepositories.describe(error)))
        }
        addNext()
      }
    }
    guard !failures.isEmpty else { return }
    let noun = failures.count == 1 ? failures[0].name : String(localized: "\(failures.count) repositories")
    let reasons = failures.map { failure in
      let message = failure.message.split(separator: "\n").first.map(String.init) ?? ""
      return failures.count == 1 ? message : "\(failure.name): \(message)"
    }
    failure = RemoteFailure(
      title: String(localized: "Couldn’t refresh \(noun)"),
      message: (reasons + [String(localized: "Their marks are as their device last wrote them, with how long ago.")])
        .joined(separator: "\n\n"))
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
