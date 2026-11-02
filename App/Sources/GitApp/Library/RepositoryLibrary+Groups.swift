import Foundation
import ComponentKit
import GitKit
import GitRemote
import SwiftData
import VaultKit

/// A sidebar item: a group, or a repository.
enum SidebarItem: Identifiable {
  case group(VaultProjectGroup)
  case repository(SavedRepository)

  /// A repository's path, or `group:<id>`.
  var id: String {
    switch self {
    case .group(let group): Self.id(of: group)
    case .repository(let repository): repository.path
    }
  }

  static func id(of group: VaultProjectGroup) -> String { "group:\(group.id)" }

  var name: String {
    switch self {
    case .group(let group): group.name
    case .repository(let repository): repository.name
    }
  }
}

/// The sidebar's arrangement: the vault's project tree (`VaultProjectTree`, shared with the other v57
/// apps and Macs) cut down to the repositories in the list, with the ones the vault doesn't list yet
/// at the end of the top level.
struct SidebarLayout {
  /// The groups and projects that hold a repository in the list.
  let tree: VaultProjectTree
  private let device: String
  private let repositories: [String: SavedRepository]
  /// Path → project id.
  private let projectIDs: [String: String]
  /// Path → the project's icon (`VaultProject.icon`), for those that have one.
  private let icons: [String: Data]
  private let loose: [SavedRepository]

  init(repositories: [SavedRepository], vault: Vault) {
    let device = vault.deviceID
    let byPath = Dictionary(repositories.map { ($0.path, $0) }) { first, _ in first }
    tree = vault.projectTree.filter { $0.paths[device].map { byPath[$0] != nil } ?? false }
    var ids: [String: String] = [:]
    var icons: [String: Data] = [:]
    for project in tree.projects() {
      guard let path = project.paths[device] else { continue }
      ids[path] = project.id
      icons[path] = project.icon
    }
    self.device = device
    self.repositories = byPath
    projectIDs = ids
    self.icons = icons
    loose = repositories.filter { ids[$0.path] == nil }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// The items in a group, or at the top level when `groupID` is nil.
  func children(of groupID: String?) -> [SidebarItem] {
    let items = tree.children(of: groupID).compactMap(item(for:))
    return groupID == nil ? items + loose.map(SidebarItem.repository) : items
  }

  private func item(for node: VaultProjectTree.Node) -> SidebarItem? {
    switch node {
    case .group(let group, _): .group(group)
    case .project(let project): project.paths[device].flatMap { repositories[$0] }.map(SidebarItem.repository)
    }
  }

  /// The group a repository is in; nil at the top level.
  func groupID(of path: String) -> String? { projectIDs[path].flatMap(tree.parent(of:)) }

  /// The project a repository is in the vault.
  func projectID(of path: String) -> String? { projectIDs[path] }

  /// The app icon the vault keeps for a repository's project (Git, Code and Dev find them).
  func icon(of path: String) -> Data? { icons[path] }

  /// The vault id of a sidebar item's id (a path or `group:<id>`).
  func vaultID(of itemID: String) -> String? {
    itemID.hasPrefix("group:") ? String(itemID.dropFirst(6)) : projectIDs[itemID]
  }

  /// The repositories in a group and in the groups inside it, or every one, in sidebar order.
  func repositories(in groupID: String? = nil) -> [SavedRepository] {
    let inTree = tree.projects(in: groupID).compactMap { $0.paths[device].flatMap { repositories[$0] } }
    return groupID == nil ? inTree + loose : inTree
  }

  /// A group's name with the groups it is in, e.g. "v57 › Agentus".
  func title(of group: VaultProjectGroup) -> String {
    (tree.ancestors(of: group.id).map(\.name) + [group.name]).joined(separator: " › ")
  }
}

/// How a sidebar fetch, pull or push ended; `count` grows with each, so the row's effect plays again.
struct RemoteOutcome: Equatable {
  var action: RemoteAction
  var succeeded: Bool
  var count: Int

  /// A sweep of light for a fetch, a drop for a pull, a send for a push, a shake for a failure.
  var effect: KitEffect {
    guard succeeded else { return .failure }
    switch action {
    case .fetch: return .shimmer
    case .pull: return .receive("arrow.down.circle.fill")
    case .push: return .send("arrow.up.circle.fill")
    }
  }
}

extension RepositoryLibrary {
  /// The sidebar's arrangement of the repositories in `context`.
  func layout(_ context: ModelContext) -> SidebarLayout {
    SidebarLayout(repositories: ((try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []).filter(owns), vault: vault)
  }

  // MARK: Arranging

  /// Lays the repositories out in the vault's tree as their folders are (`VaultStore.arrangeProjects`): a dropped
  /// folder in `roots` becomes a group, with groups for the folders in it that hold two or more. New groups and
  /// ungrouped repositories go into `group` before `before`.
  func arrange(_ paths: [String], roots: [String] = [], into group: String? = nil, before: String? = nil) {
    vault.perform { try $0.arrangeProjects(paths, roots: roots, into: group, before: before) }
  }

  // MARK: Moving

  /// Moves repositories into a group (or the top level when `groupID` is nil), before the sidebar
  /// item with id `before` or at the end. Groups left empty go.
  func move(_ paths: [String], into groupID: String?, before: String?, context: ModelContext) {
    let layout = layout(context)
    let ids = paths.compactMap(layout.projectID(of:))
    guard !ids.isEmpty else { return }
    vault.perform { try $0.moveProjects(ids, into: groupID, before: before.flatMap(layout.vaultID(of:))) }
  }

  /// Moves a group into another (or the top level), before the sidebar item with id `before` or at
  /// the end. A group never moves into itself or a group inside it.
  func moveGroup(_ id: String, into groupID: String?, before: String?, context: ModelContext) {
    let layout = layout(context)
    vault.perform { try $0.moveProjects([id], into: groupID, before: before.flatMap(layout.vaultID(of:))) }
  }

  /// Moves repositories and groups out of the group they are in, to just after it in the group
  /// above (or the top level).
  func moveOut(_ itemIDs: [String], context: ModelContext) {
    let layout = layout(context)
    let ids = itemIDs.compactMap(layout.vaultID(of:))
    vault.perform { try $0.moveProjectsOut(ids) }
  }

  // MARK: Groups

  /// Makes a group of `paths` where the first of them is, inside its group if it is in one. It is
  /// named after their folder when they share one.
  @discardableResult
  func newGroup(from paths: [String], context: ModelContext) -> VaultProjectGroup? {
    let layout = layout(context)
    let ids = paths.compactMap(layout.projectID(of:))
    guard !ids.isEmpty else { return nil }
    let folders = Set(paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL })
    let name = folders.count == 1 ? folders.first!.lastPathComponent : "New Group"
    let note = folders.count == 1 ? folders.first!.deletingLastPathComponent().lastPathComponent : nil
    var group: VaultProjectGroup?
    vault.perform { group = try $0.groupProjects(ids, name: name, note: note) }
    return group
  }

  /// Deletes a group and puts what it holds where it was.
  func ungroup(_ group: VaultProjectGroup) {
    vault.perform { try $0.ungroupProjects(group.id) }
    collapsedGroups.remove(group.id)
  }

  /// Takes a group's repositories, in the groups inside it too, out of the list; the vault deletes the group
  /// when no Mac has a project in it any more.
  func remove(_ group: VaultProjectGroup, members: [SavedRepository], from context: ModelContext) {
    remove(members, from: context)
    collapsedGroups.remove(group.id)
  }

  func rename(_ group: VaultProjectGroup, to name: String) {
    var group = group
    group.name = name
    vault.save(group)
  }

  func toggleCollapsed(_ group: VaultProjectGroup) {
    if collapsedGroups.contains(group.id) {
      collapsedGroups.remove(group.id)
    } else {
      collapsedGroups.insert(group.id)
    }
  }

  func setHidden(_ paths: [String], _ hidden: Bool, context: ModelContext) {
    let repositories = (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []
    for repository in repositories where paths.contains(repository.path) {
      repository.isHidden = hidden
    }
    try? context.save()
  }

  // MARK: Groups made before the vault had them

  /// Moves the groups Git kept in its own store (`SavedGroup`, one level) into the vault, once. A
  /// group with the same name that another Mac already moved there is reused.
  func moveSavedGroupsToVault(context: ModelContext) {
    let key = "MovedGroupsToVault"
    guard !UserDefaults.standard.bool(forKey: key), vault.store != nil else { return }
    let groups = (try? context.fetch(FetchDescriptor<SavedGroup>())) ?? []
    let repositories = (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []
    let layout = layout(context)
    vault.perform { store in
      let tree = try store.projectTree()
      var ids: [UUID: String] = [:]
      for saved in groups {
        if var existing = tree.groups.first(where: { $0.parentID == nil && $0.name == saved.name }) {
          if !saved.directory.isEmpty, existing.paths[store.deviceID] == nil {
            existing.paths[store.deviceID] = saved.directory
            try store.save(existing)
          }
          ids[saved.id] = existing.id
        } else {
          let group = VaultProjectGroup(
            id: saved.id.uuidString, name: saved.name, note: saved.note.isEmpty ? nil : saved.note,
            paths: saved.directory.isEmpty ? [:] : [store.deviceID: saved.directory])
          try store.save(group)
          ids[saved.id] = group.id
        }
      }
      // The old order: groups and ungrouped repositories by sortIndex, members by sortIndex.
      func sorted<T>(_ items: [(index: Int, name: String, id: T)]) -> [T] {
        items.sorted {
          $0.index != $1.index ? $0.index < $1.index : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.map(\.id)
      }
      let top: [(index: Int, name: String, id: String?)] =
        groups.map { ($0.sortIndex, $0.name, ids[$0.id]) }
        + repositories.filter { $0.groupID.flatMap { ids[$0] } == nil }
        .map { ($0.sortIndex, $0.name, layout.projectID(of: $0.path)) }
      try store.moveProjects(sorted(top).compactMap { $0 }, into: nil)
      for saved in groups {
        guard let id = ids[saved.id] else { continue }
        let members: [(index: Int, name: String, id: String?)] = repositories.filter { $0.groupID == saved.id }
          .map { ($0.sortIndex, $0.name, layout.projectID(of: $0.path)) }
        try store.moveProjects(sorted(members).compactMap { $0 }, into: id)
      }
      try store.removeEmptyProjectGroups(ids.values)
    }
    guard vault.error == nil else { return }
    for saved in groups where saved.isCollapsed {
      if let id = vault.projectGroups.first(where: { $0.id == saved.id.uuidString || $0.name == saved.name })?.id {
        collapsedGroups.insert(id)
      }
    }
    for saved in groups { context.delete(saved) }
    for repository in repositories { repository.groupID = nil }
    try? context.save()
    UserDefaults.standard.set(true, forKey: key)
  }

  // MARK: Fetch, pull and push

  /// Runs `action` in each repository (a path, or a `remoteKey` for one on another device), a few at a time, and
  /// reports the ones that failed.
  func run(_ action: RemoteAction, on paths: [String]) async {
    let paths = paths.filter { remoteActivity[$0] == nil }
    guard !paths.isEmpty else { return }
    for path in paths { remoteActivity[path] = action }
    var failures: [(name: String, message: String)] = []
    // Each with the GitHub sign-in of its account.
    let runners = paths.map { ($0, Self.isRemote($0) ? nil : runner(for: $0)) }
    await withTaskGroup(of: (String, String?).self) { group in
      var pending = runners[...]
      func addNext() {
        guard let (path, runner) = pending.popFirst() else { return }
        group.addTask {
          do {
            if let runner {
              try await action.run(in: Repository(url: URL(fileURLWithPath: path, isDirectory: true), runner: runner))
            } else {
              try await self.runOnDevice(action, key: path)
            }
            return (path, nil)
          } catch {
            return (path, (error as? GitError)?.message ?? error.localizedDescription)
          }
        }
      }
      for _ in 0..<4 { addNext() }
      for await (path, message) in group {
        remoteActivity[path] = nil
        remoteOutcomes[path] = RemoteOutcome(
          action: action, succeeded: message == nil, count: (remoteOutcomes[path]?.count ?? 0) + 1)
        if let message {
          failures.append((remoteRepository(path)?.name ?? (path as NSString).lastPathComponent, message))
        }
        if let session = sessions[path], session === openSession || Self.isRemote(path) {
          Task { await session.refresh() }
        } else if !Self.isRemote(path) {
          Task { await refreshSummaries([path]) }
        }
        addNext()
      }
    }
    if let failure = RemoteFailure(action, failures: failures) { remoteFailure = failure }
  }

  /// Runs `action` in a repository on another device: in its session when it's open, else over a connection just for
  /// this, which also reads how it is now (newer than what the device last said).
  private func runOnDevice(_ action: RemoteAction, key: String) async throws {
    if let session = sessions[key] { return try await action.run(in: session.repository) }
    guard let repository = remoteRepository(key) else {
      throw GitError(message: "The repository isn’t on any of your devices any more.")
    }
    if let summary = try await RemoteRepositories.run(action, on: repository, vault: vault) { checked(key, summary) }
  }

  // MARK: Left out of On Your Devices

  /// Hides repositories on other devices on this Mac (Show Hidden shows them dimmed).
  func setRemoteHidden(_ ids: [String], _ hidden: Bool) {
    if hidden { hiddenRemotes.formUnion(ids) } else { hiddenRemotes.subtract(ids) }
  }

  /// Takes repositories on other devices out of this Mac's list until Restore; they stay on those devices and in the
  /// vault.
  func removeRemotes(_ ids: [String]) {
    removedRemotes.formUnion(ids)
    hiddenRemotes.subtract(ids)
  }
}
