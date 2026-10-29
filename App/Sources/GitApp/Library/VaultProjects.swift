import Foundation
import GitKit
import SwiftData
import VaultKit

/// Keeps the sidebar's repositories and the vault's projects the same, so a repository added here appears in
/// Code, Dev, Markdown and Shell, and one another app added on this Mac appears here.
///
/// The vault (`../Vault`) is the store every v57 app shares; a project there is a folder per device plus its
/// remote URL and its place in the project tree, whose groups are the sidebar's (`SidebarLayout`). Git
/// publishes when repositories are added, opened (the remote may have changed) or removed, and adopts the
/// vault's git checkouts on this Mac it doesn't list yet, at launch and whenever any app changes the vault.
@MainActor final class VaultProjects {
  let vault: Vault
  private var observer: VaultChangeObserver?

  /// Whether this is the shared vault. Debug launches with `--in-memory` (screenshots, scripted runs) use
  /// a vault of their own instead, which must not change the real list.
  let isShared: Bool

  /// The window's vault: Personal or the account the window shows (`VaultAccountScope`).
  init(vault: Vault) {
    #if DEBUG
      if let memory = Self.inMemory {
        self.vault = memory
        isShared = false
        return
      }
    #endif
    self.vault = vault
    isShared = true
  }

  #if DEBUG
    /// The `--in-memory` launches' vault, one for every window.
    private static let inMemory: Vault? = {
      guard ProcessInfo.processInfo.arguments.contains("--in-memory") else { return nil }
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dev.v57.git-vault-\(UUID().uuidString)", isDirectory: true)
      return Vault(store: try? VaultStore(directory: directory, keys: MemoryKeyProvider(), notifier: nil))
    }()
  #endif

  /// Whether a repository belongs to the window's account; repositories saved before accounts are Personal's.
  func owns(_ repository: SavedRepository) -> Bool {
    (repository.accountID ?? VaultAccount.personal.id) == vault.accountID
  }

  /// Starts sync and adoption for the window's context.
  func start(context: ModelContext, library: RepositoryLibrary) {
    guard observer == nil else { return }
    observer = VaultChangeObserver { [weak self, weak library] in
      Task { @MainActor in
        guard let self, let library else { return }
        self.vault.reload()
        self.adopt(into: context, library: library)
      }
    }
    Task {
      await publishMissing(context: context)
      if isShared && vault.isPersonal { library.moveSavedGroupsToVault(context: context) }
      adopt(into: context, library: library)
    }
  }

  /// Publishes repositories (with their `origin`) to the vault.
  func publish(_ repositories: [SavedRepository], context: ModelContext) async {
    guard let store = vault.store, !repositories.isEmpty else { return }
    let entries = repositories.map { ($0.path, $0.name) }
    for (path, name) in entries {
      let remote = try? await Repository(url: URL(fileURLWithPath: path, isDirectory: true)).remoteURL("origin")
      do {
        try store.addProject(path: path, name: name, remoteURL: remote?.isEmpty == false ? remote : nil)
      } catch {
        vault.error = error.localizedDescription
      }
    }
    vault.reload()
  }

  /// Removes repositories from the vault (from this Mac; the project goes when no device has it).
  func unpublish(_ paths: [String]) {
    vault.perform { store in
      for path in paths { try store.removeProject(path: path) }
    }
  }

  /// Repositories the vault doesn't have yet (the first launch with the vault, or ones added offline).
  private func publishMissing(context: ModelContext) async {
    let known = Set(vault.localProjects.compactMap(\.localPath))
    let repositories = ((try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []).filter {
      owns($0) && !known.contains($0.path)
    }
    await publish(repositories, context: context)
  }

  /// Adds the vault's projects on this Mac that are git checkouts and aren't in the sidebar (of any account: a
  /// repository is in one account's list).
  func adopt(into context: ModelContext, library: RepositoryLibrary) {
    let saved = Set(((try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []).map(\.path))
    let fileManager = FileManager.default
    let candidates = vault.localProjects.compactMap(\.localPath).filter { path in
      !saved.contains(path) && fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }
    guard !candidates.isEmpty else { return }
    library.adopt(candidates, into: context)
  }
}
