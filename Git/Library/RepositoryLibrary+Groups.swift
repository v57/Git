import AppKit
import ComponentKit
import GitKit
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

  // MARK: Dragging groups

  /// Groups are dragged as `x-git-group:<id>` URLs, so one drop destination for URLs takes
  /// repositories (file URLs), groups and folders from Finder.
  static let groupScheme = "x-git-group"

  static func dragURL(for group: VaultProjectGroup) -> URL {
    URL(string: "\(groupScheme):\(group.id)")!
  }

  static func groupID(fromDragURL url: URL) -> String? {
    guard url.scheme == groupScheme else { return nil }
    let id = String(url.absoluteString.dropFirst(groupScheme.count + 1))
    return id.isEmpty ? nil : id
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
  private let loose: [SavedRepository]

  init(repositories: [SavedRepository], vault: Vault) {
    let device = vault.deviceID
    let byPath = Dictionary(repositories.map { ($0.path, $0) }) { first, _ in first }
    tree = vault.projectTree.filter { $0.paths[device].map { byPath[$0] != nil } ?? false }
    var ids: [String: String] = [:]
    for project in tree.projects() {
      if let path = project.paths[device] { ids[path] = project.id }
    }
    self.device = device
    self.repositories = byPath
    projectIDs = ids
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

/// A network operation started on repositories from the sidebar.
enum RemoteAction: String {
  case fetch, pull, push

  var title: String {
    switch self {
    case .fetch: "Fetch"
    case .pull: "Pull"
    case .push: "Push"
    }
  }

  var systemImage: String {
    switch self {
    case .fetch: "arrow.clockwise"
    case .pull: "arrow.down.to.line"
    case .push: "arrow.up.to.line"
    }
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

struct RemoteFailure: Identifiable {
  let id = UUID()
  var title: String
  var message: String
}

extension RepositoryLibrary {
  /// The sidebar's arrangement of the repositories in `context`.
  func layout(_ context: ModelContext) -> SidebarLayout {
    SidebarLayout(repositories: (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? [], vault: vault)
  }

  // MARK: Arranging

  /// Puts repositories in no group into groups by folder (see `RepoGrouping`): siblings join the
  /// group made from their folder, created if needed (inside the group of the nearest folder above
  /// that has one), and a repository whose folder already has a group joins it. New repositories
  /// left over go to the end of the top level, in name order with the new groups.
  func arrange(_ paths: [String], new: Set<String>) {
    vault.perform { store in
      let device = store.deviceID
      let tree = try store.projectTree()
      var projects: [String: VaultProject] = [:]
      for project in tree.projects() {
        if let path = project.paths[device] { projects[path] = project }
      }
      let candidates = paths.compactMap { projects[$0] }.filter { tree.parent(of: $0.id) == nil }
      guard !candidates.isEmpty else { return }
      var folders = [String: String](
        tree.groups.compactMap { group in group.paths[device].map { ($0, group.id) } }
      ) { first, _ in first }
      var newItems: [(name: String, id: String)] = []

      let plan = RepoGrouping.groups(
        for: candidates.compactMap { $0.paths[device] }.map { URL(fileURLWithPath: $0, isDirectory: true) })
      var placed = Set<String>()
      // Outer folders first, so a folder's group exists before the groups inside it.
      for planned in plan.groups.sorted(by: { $0.directory.path.count < $1.directory.path.count }) {
        let directory = planned.directory.path
        let groupID: String
        if let existing = folders[directory] {
          groupID = existing
        } else {
          let parent = folders.filter { directory.hasPrefix($0.key + "/") }.max { $0.key.count < $1.key.count }?.value
          let group = try store.addProjectGroup(
            name: planned.name, note: planned.note.isEmpty ? nil : planned.note, path: directory, in: parent)
          folders[directory] = group.id
          groupID = group.id
          if parent == nil { newItems.append((group.name, group.id)) }
        }
        let ids = planned.repositories.compactMap { projects[$0.path]?.id }
        try store.moveProjects(ids, into: groupID)
        placed.formUnion(ids)
      }
      for project in candidates where !placed.contains(project.id) {
        guard let path = project.paths[device] else { continue }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        if let groupID = folders[folder] {
          try store.moveProjects([project.id], into: groupID)
        } else if new.contains(path) {
          newItems.append((project.name, project.id))
        }
      }
      let order = newItems.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      try store.moveProjects(order.map(\.id), into: nil)
    }
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
    vault.perform { store in
      let tree = try store.projectTree()
      let byGroup = Dictionary(grouping: ids.filter { tree.parent(of: $0) != nil }) { tree.parent(of: $0)! }
      for (groupID, ids) in byGroup {
        let parent = tree.parent(of: groupID)
        let siblings = tree.children(of: parent).map(\.id)
        let next = siblings.firstIndex(of: groupID).flatMap { $0 + 1 < siblings.count ? siblings[$0 + 1] : nil }
        try store.moveProjects(ids, into: parent, before: next)
      }
    }
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

  /// Runs `action` in each repository, a few at a time, and reports the ones that failed.
  func run(_ action: RemoteAction, on paths: [String]) async {
    let paths = paths.filter { remoteActivity[$0] == nil }
    guard !paths.isEmpty else { return }
    for path in paths { remoteActivity[path] = action }
    var failures: [(name: String, message: String)] = []
    await withTaskGroup(of: (String, String?).self) { group in
      var pending = paths[...]
      func addNext() {
        guard let path = pending.popFirst() else { return }
        group.addTask {
          let repository = Repository(url: URL(fileURLWithPath: path, isDirectory: true))
          do {
            switch action {
            case .fetch: try await repository.fetch()
            case .pull: try await repository.pull()
            case .push: try await repository.push()
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
          failures.append(((path as NSString).lastPathComponent, message))
        }
        if let session = sessions[path], session === openSession {
          Task { await session.refresh() }
        } else {
          Task { await refreshSummaries([path]) }
        }
        addNext()
      }
    }
    guard !failures.isEmpty else { return }
    let noun = failures.count == 1 ? "repository" : "\(failures.count) repositories"
    remoteFailure = RemoteFailure(
      title: "Couldn't \(action.title.lowercased()) \(failures.count == 1 ? failures[0].name : noun)",
      message: failures.map { failure in
        let message = failure.message.split(separator: "\n").prefix(3).joined(separator: "\n")
        return failures.count == 1 ? message : "\(failure.name): \(message)"
      }.joined(separator: "\n\n"))
  }
}
