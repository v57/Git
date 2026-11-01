#if DEBUG
  import Foundation
  import GitEngine
  import GitKit
  import GitRemote
  import SwiftUI
  import VaultKit

  /// Debug builds take repositories and steps from the launch environment, for trying the app in the simulator
  /// (which has no Secure Enclave key and no Hub) without tapping:
  ///
  /// - `GIT_DEBUG_REMOTE`: repositories on another machine (GitRemote's `DebugRemotes`); one with a `group` becomes a
  ///   vault project in that group in this device's vault, as the Mac's projects are.
  /// - `GIT_DEBUG_SELECT`: the repository opened at launch (its name), or `none`. Else the first debug remote.
  /// - `GIT_DEBUG_CLONE`: an HTTPS URL cloned to this device at launch (unless a folder of its name is there), then
  ///   opened.
  /// - `GIT_DEBUG_SHEET`: `clone`, `create`, `addRemote` or `settings`, shown at launch.
  /// - `GIT_DEBUG_SHOW`: `history`, `commit:<index>` or `diff:<path>`, once the repository is open.
  /// - `GIT_DEBUG_PERFORM`: steps separated by `;`: `stage:<path>`, `stageAll`, `unstageAll`, `commit:<message>`,
  ///   `fetch`, `pull`, `push`, `branch:<name>`, `switch:<name>`, run in order once it's open.
  ///
  /// The open repository's state goes to `Library/Caches/git-debug-state.txt` in the app's container as it changes:
  ///
  ///     SIMCTL_CHILD_GIT_DEBUG_REMOTE='{…}' xcrun simctl launch <udid> dev.v57.git
  @MainActor enum DebugLaunch {
    static let environment = ProcessInfo.processInfo.environment

    /// `GIT_DEBUG_REMOTE`'s repositories (GitRemote's `DebugRemotes`, which the Mac app reads too).
    static var remotes: [DebugRemotes.Remote] { DebugRemotes.remotes }
    static var repositories: [RemoteRepository] { DebugRemotes.repositories }

    /// The debug remotes with a `group`, as vault projects in that group, so the list shows them as it shows the
    /// Mac's projects.
    static func addGroupedProjects(to vault: Vault) {
      let grouped = Dictionary(grouping: remotes.filter { $0.group != nil }, by: { $0.group ?? "" })
      guard !grouped.isEmpty else { return }
      guard vault.store != nil else {
        write("vault: no store (\(vault.error ?? "no error"))\n")
        return
      }
      vault.perform { store in
        for (name, remotes) in grouped.sorted(by: { $0.key < $1.key }) {
          let ids = remotes.map(DebugRemotes.id(of:))
          for (remote, id) in zip(remotes, ids) where try store.record(VaultProject.self, id: id) == nil {
            _ = try store.save(VaultProject(id: id, name: remote.name))
          }
          let tree = try store.projectTree()
          if ids.contains(where: { tree.parent(of: $0).flatMap(tree.group(id:))?.name != name }) {
            _ = try store.groupProjects(ids, name: name)
          }
        }
      }
      write("vault: \(vault.projects.count) projects, \(vault.projectGroups.count) groups, error \(vault.error ?? "-")\n")
    }

    static var sheet: LibrarySheet? { environment["GIT_DEBUG_SHEET"].flatMap(LibrarySheet.init(rawValue:)) }

    /// The repository opened at launch, after `GIT_DEBUG_CLONE` cloned one.
    static func selected(in sources: [RepositorySource]) async -> RepositorySource.ID? {
      if let url = environment["GIT_DEBUG_CLONE"] {
        let name = LocalRepositories.name(ofRemote: url)
        let local = LocalRepositories.shared
        if !local.repositories.contains(where: { $0.name == name }) {
          write("cloning \(url)\n")
          do {
            _ = try await local.clone(url) { line in Task { @MainActor in write("clone: \(line)\n") } }
          } catch {
            write("clone failed: \(RepositoryModel.describe(error))\n")
            return nil
          }
        }
        return local.repositories.first { $0.name == name }.map { RepositorySource.local($0).id }
      }
      let select = environment["GIT_DEBUG_SELECT"]
      if select == "none" { return nil }
      let all = sources + repositories.map(RepositorySource.remote)
      if let select { return all.first { $0.name == select }?.id }
      return repositories.first.map { RepositorySource.remote($0).id }
    }

    /// Shows `GIT_DEBUG_SHOW`, runs `GIT_DEBUG_PERFORM`, and keeps writing the state.
    static func attach(to model: RepositoryModel, pane: Binding<RepositoryScreen.Pane>) async {
      Task { [weak model] in
        var written = ""
        while let model {
          let state = describe(model)
          if state != written {
            written = state
            write(state)
          }
          try? await Task.sleep(for: .milliseconds(400))
        }
      }
      for step in (environment["GIT_DEBUG_PERFORM"] ?? "").split(separator: ";").map(String.init) {
        await perform(step, on: model)
      }
      switch environment["GIT_DEBUG_SHOW"] {
      case "history"?: pane.wrappedValue = .history
      default: break
      }
    }

    private static func perform(_ step: String, on model: RepositoryModel) async {
      let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
      let argument = parts.count > 1 ? parts[1] : ""
      switch parts.first ?? "" {
      case "stage":
        if let change = model.status?.unstaged.first(where: { $0.path == argument }) { await model.stage([change]) }
      case "stageAll": await model.stageAll()
      case "unstageAll": await model.unstageAll()
      case "commit": _ = await model.commit(message: argument)
      case "fetch": await model.sync(.fetch)
      case "pull": await model.sync(.pull)
      case "push": await model.sync(.push)
      case "branch": _ = await model.createBranch(argument)
      case "switch":
        if let branch = model.branches.first(where: { $0.name == argument }) { await model.switchTo(branch) }
      default: break
      }
    }

    private static func describe(_ model: RepositoryModel) -> String {
      var lines = [
        "phase: \(model.phase)",
        "path: \(model.path ?? "-")",
        "activity: \(model.activity ?? "-") \(model.progress ?? "")",
        "branch: \(model.status?.branch ?? "-") ahead \(model.status?.ahead ?? 0) behind \(model.status?.behind ?? 0) upstream \(model.status?.upstream ?? "-")",
        "staged: \(model.status?.staged.map(\.path).joined(separator: ", ") ?? "-")",
        "unstaged: \(model.status?.unstaged.map { "\($0.kind.letter) \($0.path)" }.joined(separator: ", ") ?? "-")",
        "branches: \(model.branches.map { ($0.isCurrent ? "*" : "") + $0.name }.joined(separator: ", "))",
        "commits: \(model.commits.count)",
        "failure: \(model.failure.map { "\($0.title): \($0.message)" } ?? "-")",
      ]
      lines += model.commits.prefix(5).map { "  \($0.shortID) \($0.subject)" }
      return lines.joined(separator: "\n") + "\n"
    }

    static func write(_ state: String) {
      guard let documents = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
      try? Data(state.utf8).write(to: documents.appendingPathComponent("git-debug-state.txt"), options: .atomic)
    }
  }
#endif
