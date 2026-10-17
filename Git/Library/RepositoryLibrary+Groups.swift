import AppKit
import ComponentKit
import GitKit
import SwiftData

/// A top-level sidebar item: a group, or a repository in no group.
enum SidebarItem: Identifiable {
  case group(SavedGroup)
  case repository(SavedRepository)

  /// A repository's path, or `group:<uuid>`.
  var id: String {
    switch self {
    case .group(let group): Self.id(of: group)
    case .repository(let repository): repository.path
    }
  }

  static func id(of group: SavedGroup) -> String { "group:\(group.id.uuidString)" }

  var name: String {
    switch self {
    case .group(let group): group.name
    case .repository(let repository): repository.name
    }
  }

  var sortIndex: Int {
    get {
      switch self {
      case .group(let group): group.sortIndex
      case .repository(let repository): repository.sortIndex
      }
    }
    nonmutating set {
      switch self {
      case .group(let group): group.sortIndex = newValue
      case .repository(let repository): repository.sortIndex = newValue
      }
    }
  }

  // MARK: Dragging groups

  /// Groups are dragged as `x-git-group:<uuid>` URLs, so one drop destination for URLs takes
  /// repositories (file URLs), groups and folders from Finder.
  static let groupScheme = "x-git-group"

  static func dragURL(for group: SavedGroup) -> URL {
    URL(string: "\(groupScheme):\(group.id.uuidString)")!
  }

  static func groupID(fromDragURL url: URL) -> UUID? {
    guard url.scheme == groupScheme else { return nil }
    return UUID(uuidString: String(url.absoluteString.dropFirst(groupScheme.count + 1)))
  }
}

/// The sidebar's order: top-level items, and each group's repositories.
struct SidebarLayout {
  var items: [SidebarItem]
  var members: [UUID: [SavedRepository]]

  init(repositories: [SavedRepository], groups: [SavedGroup]) {
    let groupIDs = Set(groups.map(\.id))
    // A repository whose group is gone shows at the top level.
    let loose = repositories.filter { $0.groupID.map { !groupIDs.contains($0) } ?? true }
    items = Self.ordered(groups.map(SidebarItem.group) + loose.map(SidebarItem.repository))
    var members: [UUID: [SavedRepository]] = [:]
    for repository in repositories {
      guard let id = repository.groupID, groupIDs.contains(id) else { continue }
      members[id, default: []].append(repository)
    }
    self.members = members.mapValues(Self.ordered)
  }

  static func ordered(_ items: [SidebarItem]) -> [SidebarItem] {
    items.sorted {
      $0.sortIndex != $1.sortIndex
        ? $0.sortIndex < $1.sortIndex
        : $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  static func ordered(_ repositories: [SavedRepository]) -> [SavedRepository] {
    ordered(repositories.map(SidebarItem.repository)).compactMap {
      if case .repository(let repository) = $0 { repository } else { nil }
    }
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
  // MARK: Arranging

  /// Puts repositories that are new or in no group into groups by folder (see `RepoGrouping`):
  /// siblings join the group made from their folder, created if needed, and a repository whose
  /// folder already has a group joins it. New repositories left over go to the end of the top
  /// level, in name order with the new groups.
  func arrange(_ candidates: [SavedRepository], new: Set<String>, context: ModelContext) {
    guard !candidates.isEmpty else { return }
    let repositories = (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []
    var groups = (try? context.fetch(FetchDescriptor<SavedGroup>())) ?? []
    let candidatePaths = Set(candidates.map(\.path))
    let byPath = Dictionary(candidates.map { ($0.path, $0) }) { first, _ in first }
    let settled = SidebarLayout(
      repositories: repositories.filter { !new.contains($0.path) }, groups: groups)
    var nextIndex = (settled.items.map(\.sortIndex).max() ?? -1) + 1
    var newItems: [SidebarItem] = []

    var nextMemberIndex: [UUID: Int] = [:]
    func join(_ repository: SavedRepository, _ group: SavedGroup) {
      let index =
        nextMemberIndex[group.id]
        ?? repositories.filter { $0.groupID == group.id && !candidatePaths.contains($0.path) }
        .map { $0.sortIndex + 1 }.max() ?? 0
      repository.groupID = group.id
      repository.sortIndex = index
      nextMemberIndex[group.id] = index + 1
    }

    let plan = RepoGrouping.groups(for: candidates.map(\.url))
    var placed = Set<String>()
    for planned in plan.groups {
      let directory = planned.directory.path
      let group: SavedGroup
      if let existing = groups.first(where: { $0.directory == directory }) {
        group = existing
      } else {
        group = SavedGroup(name: planned.name, note: planned.note, directory: directory)
        context.insert(group)
        groups.append(group)
        newItems.append(.group(group))
      }
      for url in planned.repositories {
        guard let repository = byPath[url.path] else { continue }
        join(repository, group)
        placed.insert(repository.path)
      }
    }
    for repository in candidates where !placed.contains(repository.path) {
      let folder = repository.url.deletingLastPathComponent().standardizedFileURL.path
      if let group = groups.first(where: { $0.directory == folder }) {
        join(repository, group)
      } else if new.contains(repository.path) {
        repository.groupID = nil
        newItems.append(.repository(repository))
      }
    }
    for item in newItems.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
      item.sortIndex = nextIndex
      nextIndex += 1
    }
  }

  /// Groups the repositories added before groups existed, once.
  func groupExistingRepositories(context: ModelContext) {
    let key = "GroupedExistingRepositories"
    #if DEBUG
      // A scripted in-memory run mustn't mark the real list as done.
      if ProcessInfo.processInfo.arguments.contains("--in-memory") { return }
    #endif
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    let groups = (try? context.fetch(FetchDescriptor<SavedGroup>())) ?? []
    let repositories = (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []
    guard !repositories.isEmpty else { return }
    UserDefaults.standard.set(true, forKey: key)
    guard groups.isEmpty else { return }
    arrange(repositories, new: Set(repositories.map(\.path)), context: context)
    try? context.save()
  }

  // MARK: Moving

  /// Moves repositories into a group (or the top level when `groupID` is nil), before the item
  /// with id `before` or at the end. Groups left empty are deleted.
  func move(_ paths: [String], into groupID: UUID?, before: String?, context: ModelContext) {
    let repositories = (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []
    let groups = (try? context.fetch(FetchDescriptor<SavedGroup>())) ?? []
    let moving = paths.compactMap { path in repositories.first { $0.path == path } }
    guard !moving.isEmpty else { return }
    let movingPaths = Set(moving.map(\.path))
    let layout = SidebarLayout(repositories: repositories, groups: groups)
    let formerGroups = Set(moving.compactMap(\.groupID))

    if let groupID {
      let members = layout.members[groupID] ?? []
      var rest = members.filter { !movingPaths.contains($0.path) }
      let index = anchor(before, in: members.map(\.path), skipping: movingPaths)
        .flatMap { id in rest.firstIndex { $0.path == id } } ?? rest.count
      rest.insert(contentsOf: moving, at: index)
      for (index, repository) in rest.enumerated() {
        repository.groupID = groupID
        repository.sortIndex = index
      }
    } else {
      var rest = layout.items.filter { !movingPaths.contains($0.id) }
      let index = anchor(before, in: layout.items.map(\.id), skipping: movingPaths)
        .flatMap { id in rest.firstIndex { $0.id == id } } ?? rest.count
      for repository in moving { repository.groupID = nil }
      rest.insert(contentsOf: moving.map(SidebarItem.repository), at: index)
      for (index, item) in rest.enumerated() { item.sortIndex = index }
    }
    deleteEmptyGroups(formerGroups.subtracting(groupID.map { [$0] } ?? []), context: context)
    try? context.save()
  }

  /// Moves a group before the top-level item with id `before`, or to the end.
  func moveGroup(_ id: UUID, before: String?, context: ModelContext) {
    let repositories = (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []
    let groups = (try? context.fetch(FetchDescriptor<SavedGroup>())) ?? []
    guard let group = groups.first(where: { $0.id == id }) else { return }
    let layout = SidebarLayout(repositories: repositories, groups: groups)
    let groupItemID = SidebarItem.id(of: group)
    var rest = layout.items.filter { $0.id != groupItemID }
    let index = anchor(before, in: layout.items.map(\.id), skipping: [groupItemID])
      .flatMap { id in rest.firstIndex { $0.id == id } } ?? rest.count
    rest.insert(.group(group), at: index)
    for (index, item) in rest.enumerated() { item.sortIndex = index }
    try? context.save()
  }

  /// The first id at or after `before` that isn't moving, so dropping on a moving item works.
  private func anchor(_ before: String?, in ids: [String], skipping moving: Set<String>) -> String? {
    guard let before, let start = ids.firstIndex(of: before) else { return nil }
    return ids[start...].first { !moving.contains($0) }
  }

  // MARK: Groups

  /// Makes a group of `paths` where the first of them is. It is named after their folder when
  /// they share one.
  @discardableResult
  func newGroup(from paths: [String], context: ModelContext) -> SavedGroup? {
    let repositories = (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []
    let groups = (try? context.fetch(FetchDescriptor<SavedGroup>())) ?? []
    let moving = paths.compactMap { path in repositories.first { $0.path == path } }
    guard let first = moving.first else { return nil }
    let folders = Set(moving.map { $0.url.deletingLastPathComponent().standardizedFileURL })
    let group: SavedGroup
    if folders.count == 1, let folder = folders.first {
      group = SavedGroup(
        name: folder.lastPathComponent, note: folder.deletingLastPathComponent().lastPathComponent)
    } else {
      group = SavedGroup(name: "New Group")
    }
    context.insert(group)

    let layout = SidebarLayout(repositories: repositories, groups: groups)
    let movingPaths = Set(moving.map(\.path))
    let place = first.groupID.flatMap { id in groups.first { $0.id == id } }.map(SidebarItem.id(of:))
      ?? first.path
    var rest = layout.items.filter { !movingPaths.contains($0.id) }
    let index = anchor(place, in: layout.items.map(\.id), skipping: movingPaths)
      .flatMap { id in rest.firstIndex { $0.id == id } } ?? rest.count
    rest.insert(.group(group), at: index)
    for (index, item) in rest.enumerated() { item.sortIndex = index }

    let formerGroups = Set(moving.compactMap(\.groupID))
    for (index, repository) in moving.enumerated() {
      repository.groupID = group.id
      repository.sortIndex = index
    }
    deleteEmptyGroups(formerGroups, context: context)
    try? context.save()
    return group
  }

  /// Deletes a group and puts its repositories where it was.
  func ungroup(_ group: SavedGroup, context: ModelContext) {
    let repositories = (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []
    let groups = (try? context.fetch(FetchDescriptor<SavedGroup>())) ?? []
    let layout = SidebarLayout(repositories: repositories, groups: groups)
    let members = layout.members[group.id] ?? []
    var items = layout.items
    let index = items.firstIndex { $0.id == SidebarItem.id(of: group) } ?? items.count
    items.remove(at: index)
    items.insert(contentsOf: members.map(SidebarItem.repository), at: index)
    for repository in members { repository.groupID = nil }
    for (index, item) in items.enumerated() { item.sortIndex = index }
    context.delete(group)
    try? context.save()
  }

  func setHidden(_ paths: [String], _ hidden: Bool, context: ModelContext) {
    let repositories = (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []
    for repository in repositories where paths.contains(repository.path) {
      repository.isHidden = hidden
    }
    try? context.save()
  }

  func deleteEmptyGroups(_ ids: Set<UUID>, context: ModelContext) {
    guard !ids.isEmpty else { return }
    let repositories = (try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []
    let groups = (try? context.fetch(FetchDescriptor<SavedGroup>())) ?? []
    for group in groups where ids.contains(group.id) {
      if !repositories.contains(where: { $0.groupID == group.id }) { context.delete(group) }
    }
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
