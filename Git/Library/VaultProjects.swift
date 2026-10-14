import Foundation
import GitKit
import SwiftData
import VaultKit

/// Keeps the sidebar's repositories and the vault's projects the same, so a repository added here appears in
/// Code, Dev, Markdown and Shell, and one another app added on this Mac appears here.
///
/// The vault (`../Vault`) is the store every v57 app shares; a project there is a folder per device plus its
/// remote URL and group. Git publishes when repositories are added, opened (the remote may have changed) or
/// removed, and adopts the vault's git checkouts on this Mac it doesn't list yet, at launch and whenever any
/// app changes the vault.
@MainActor final class VaultProjects {
  private let vault: Vault
  private var observer: VaultChangeObserver?

  /// Off for debug launches with `--in-memory` (screenshots, scripted runs), which must not change the
  /// real list.
  private let isEnabled: Bool

  init(vault: Vault = .shared) {
    self.vault = vault
    #if DEBUG
      isEnabled = !ProcessInfo.processInfo.arguments.contains("--in-memory")
    #else
      isEnabled = true
    #endif
  }

  /// Starts sync and adoption for the window's context.
  func start(context: ModelContext, library: RepositoryLibrary) {
    guard isEnabled, observer == nil else { return }
    observer = VaultChangeObserver { [weak self, weak library] in
      Task { @MainActor in
        guard let self, let library else { return }
        self.vault.reload()
        self.adopt(into: context, library: library)
      }
    }
    Task {
      await publishMissing(context: context)
      adopt(into: context, library: library)
    }
  }

  /// Publishes repositories (with their `origin` and sidebar group) to the vault.
  func publish(_ repositories: [SavedRepository], context: ModelContext) async {
    guard isEnabled, let store = vault.store, !repositories.isEmpty else { return }
    let groups = Dictionary(
      ((try? context.fetch(FetchDescriptor<SavedGroup>())) ?? []).map { ($0.id, $0.name) }
    ) { first, _ in first }
    let entries = repositories.map { ($0.path, $0.name, $0.groupID.flatMap { groups[$0] }) }
    for (path, name, group) in entries {
      let remote = try? await Repository(url: URL(fileURLWithPath: path, isDirectory: true)).remoteURL("origin")
      do {
        try store.addProject(path: path, name: name, remoteURL: remote?.isEmpty == false ? remote : nil, group: group)
      } catch {
        vault.error = error.localizedDescription
      }
    }
    vault.reload()
  }

  /// Removes repositories from the vault (from this Mac; the project goes when no device has it).
  func unpublish(_ paths: [String]) {
    guard isEnabled else { return }
    vault.perform { store in
      for path in paths { try store.removeProject(path: path) }
    }
  }

  /// Repositories the vault doesn't have yet (the first launch with the vault, or ones added offline).
  private func publishMissing(context: ModelContext) async {
    let known = Set(vault.localProjects.compactMap(\.localPath))
    let repositories = ((try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []).filter { !known.contains($0.path) }
    await publish(repositories, context: context)
  }

  /// Adds the vault's projects on this Mac that are git checkouts and aren't in the sidebar.
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
