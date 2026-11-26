import ComponentKit
import GitKit
import GitRemote
import GitUI
import SwiftUI

/// Recent: the repositories opened last, at the top of the sidebar, each with its branch and state. Hidden while
/// nothing was opened yet (or none of them matches the filter). The ids are the sidebar's selections: a path, or a
/// `remoteKey` for one on another device.
struct RecentRepositoriesSection: View {
  @Environment(RepositoryLibrary.self) private var library
  let recents: KitRecents
  let repositories: [SavedRepository]
  @Binding var selection: String?
  let filter: String

  /// A recent repository that is still listed: one on this Mac, or one on another device.
  private struct Item: Identifiable {
    let id: String
    var name: String
    var icon: Data?
    var summary: RepositorySummary?
    var places: String?
    var isMissing = false
  }

  private var items: [Item] {
    let ids = recents.ids
    guard !ids.isEmpty else { return [] }
    let layout = SidebarLayout(repositories: repositories, vault: library.vault)
    let items: [Item] = ids.compactMap { id in
      if RepositoryLibrary.isRemote(id) {
        guard let remote = library.remoteRepository(id) else { return nil }
        return Item(
          id: id, name: remote.name, icon: remote.icon, summary: library.remoteSummary(remote), places: remote.places)
      }
      guard let saved = repositories.first(where: { $0.path == id }) else { return nil }
      return Item(
        id: id, name: saved.name, icon: layout.icon(of: id), summary: library.summaries[id], isMissing: !saved.exists)
    }
    return items.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
  }

  var body: some View {
    let items = items
    if !items.isEmpty {
      KitSection("Recent", meta: [String(localized: "\(items.count) repositories")], systemImage: "clock", hue: .gray) {
        ForEach(items) { item in
          SidebarRow(item.name, subtitle: subtitle(item)) {
            Avatar(name: item.name, imageData: item.icon, kind: .thing, size: 18)
          } trailing: {
            if item.isMissing {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Hue.orange.fill)
                .help("Missing")
            } else if let summary = item.summary {
              StatusMarks(summary: summary)
            }
          }
          .action {
            selection = item.id
            if library.showsAllRepositories { withKitAnimation { library.showsAllRepositories = false } }
          }
          .kitHelp(
            item.name,
            meta: [RepositoryLibrary.isRemote(item.id) ? item.places : item.id, item.summary.map(StatusMarks.description)]
              .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
          .transition(.row)
        }
      }
      .animation(.kit, value: items.map(\.id))
    }
  }

  /// The branch (or the commit while detached), then the devices one on another device is on.
  private func subtitle(_ item: Item) -> String? {
    let branch = item.summary.flatMap { $0.branch ?? $0.headOID.map { String($0.prefix(7)) } }
    let parts = [branch, item.places].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

/// The bottom bar's buttons beside Add: Fetch All (every repository the list shows, as the All Repositories page's),
/// Clone (the Clone sheet) and Commit (the open repository's Changes, where the commit is written).
struct SidebarBarButtons: View {
  @Environment(RepositoryLibrary.self) private var library
  let repositories: [SavedRepository]
  /// The repository on screen.
  let shown: String?

  var body: some View {
    let paths = repositories.filter { !$0.isHidden && $0.exists }.map(\.path)
    Button("Fetch All", systemImage: "arrow.clockwise") { Task { await library.run(.fetch, on: paths) } }
      .disabled(paths.isEmpty || !library.remoteActivity.isEmpty)
      .kitHelp("Fetch All", meta: "Fetch every repository in the list", systemImage: "arrow.clockwise", hue: .blue)
    Button("Clone", systemImage: "arrow.down") { library.isClonePresented = true }
      .kitHelp("Clone", shortcut: "⇧⌘C", meta: "Clone a repository", systemImage: "arrow.down")
    Button("Commit", systemImage: "checkmark.circle") {
      guard let shown else { return }
      let state = library.viewState(for: shown)
      withKitAnimation {
        library.showsAllRepositories = false
        state.mode = .changes
        state.completedOperation = nil
      }
    }
    .disabled(shown.flatMap(library.loadedSession(for:)) == nil)
    .kitHelp("Commit", shortcut: "⌘1", meta: commitHelp, systemImage: "checkmark.circle", hue: .green)
  }

  /// "3 changes in atlas", from the sidebar's summary.
  private var commitHelp: String {
    guard let shown, library.loadedSession(for: shown) != nil else { return String(localized: "Open a repository first") }
    let name = library.displayName(of: shown)
    let count = library.summaries[shown]?.changeCount ?? 0
    return count > 0 ? String(localized: "\(count) changes in \(name)") : String(localized: "No changes in \(name)")
  }
}

extension RepositoryLibrary {
  /// A selection's name for a status line: the folder's, or the project's for one on another device.
  func displayName(of key: String) -> String {
    Self.isRemote(key) ? remoteRepository(key)?.name ?? key : (key as NSString).lastPathComponent
  }

  /// The card above the sidebar's bottom bar: the open repository's fetch, pull or push with git's progress, those
  /// started from the sidebar (and auto-fetch) by kind, and the ones that failed until their line is clicked
  /// (`dismissed`: each key's `RemoteOutcome.count` already seen).
  func activityLines(
    shown: String?, dismissed: [String: Int], select: @escaping @MainActor (String) -> Void,
    dismiss: @escaping @MainActor ([String: Int]) -> Void
  ) -> [SidebarActivity] {
    var lines: [SidebarActivity] = []
    if let shown, let session = loadedSession(for: shown), let action = session.activity.flatMap(RemoteAction.init),
      remoteActivity[shown] == nil
    {
      lines.append(
        SidebarActivity(
          id: "open", action.running([displayName(of: shown)]), detail: session.progress,
          systemImage: action.systemImage, hue: .blue,
          status: .working(progress: session.progress.flatMap(GitProgress.fraction))))
    }
    for action in [RemoteAction.fetch, .pull, .push] {
      let keys = remoteActivity.filter { $0.value == action }.keys.sorted()
      guard !keys.isEmpty else { continue }
      let names = keys.map(displayName)
      lines.append(
        SidebarActivity(
          id: "running-" + action.rawValue, action.running(names),
          detail: names.count > 1 ? names.joined(separator: ", ") : nil, systemImage: action.systemImage, hue: .blue,
          status: .working
        ) { [weak self] in
          if keys.count == 1 { select(keys[0]) } else { withKitAnimation { self?.showsAllRepositories = true } }
        })
    }
    for action in [RemoteAction.fetch, .pull, .push] {
      let failed = remoteOutcomes.filter { key, outcome in
        outcome.action == action && !outcome.succeeded && dismissed[key] != outcome.count && remoteActivity[key] == nil
      }
      guard !failed.isEmpty else { continue }
      let keys = failed.keys.sorted()
      lines.append(
        SidebarActivity(
          id: "failed-" + action.rawValue, action.failed, detail: keys.map(displayName).joined(separator: ", "),
          systemImage: action.systemImage, hue: .red, status: .failed
        ) {
          dismiss(failed.mapValues(\.count))
          if keys.count == 1 { select(keys[0]) }
        })
    }
    return lines
  }
}

extension RemoteAction {
  /// The session's activity when it is one of these.
  init?(_ activity: RepositorySession.Activity) {
    switch activity {
    case .fetching: self = .fetch
    case .pulling: self = .pull
    case .pushing: self = .push
    default: return nil
    }
  }
}
