import ComponentKit
import Foundation
import GitKit

/// How the Repositories section orders a long list (its Sort and Filter menu).
enum RepositorySort: String, CaseIterable, Identifiable {
  /// The folders' own order (dragged by hand), or by name without folders.
  case name
  /// The newest uncommitted change or commit first.
  case recentChanges
  case lastCommit
  case lastPush

  var id: Self { self }

  var title: String {
    switch self {
    case .name: "Name"
    case .recentChanges: "Recent Changes"
    case .lastCommit: "Last Commit"
    case .lastPush: "Last Push"
    }
  }

  /// The section's meta line names the order unless it's by name.
  var metaTitle: String? {
    switch self {
    case .name: nil
    case .recentChanges: "Recent changes"
    case .lastCommit: "Last commit"
    case .lastPush: "Last push"
    }
  }

  /// The date it sorts by, newest first.
  func date(_ activity: RepositoryActivity?) -> Date? {
    switch self {
    case .name: nil
    case .recentChanges: activity?.lastWorkedOn
    case .lastCommit: activity?.lastCommit
    case .lastPush: activity?.lastPush
    }
  }
}

/// The sort, the filters and the rules they share between the sidebar and the All Repositories page.
enum RepositoryOrder {
  /// A repository not worked on for this long is unused.
  static let unusedAfter: TimeInterval = 7 * 24 * 60 * 60

  /// No commit, change or open in a week. A repository whose dates haven't loaded yet counts as used.
  static func isUnused(
    _ repository: SavedRepository, activity: RepositoryActivity?, now: Date = .now
  ) -> Bool {
    guard let activity else { return false }
    let dates = [activity.lastCommit, activity.lastChange, repository.lastOpenedAt].compactMap { $0 }
    guard let newest = dates.max() else { return true }
    return now.timeIntervalSince(newest) > unusedAfter
  }

  /// Sorts by `sort`'s date, newest first, those without one last, then by name; by name for `.name`.
  static func sorted<Item>(
    _ items: [Item], by sort: RepositorySort, name: (Item) -> String, date: (Item) -> Date?
  ) -> [Item] {
    items.sorted { a, b in
      if sort != .name {
        switch (date(a), date(b)) {
        case let (x?, y?) where x != y: return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
      }
      return name(a).localizedStandardCompare(name(b)) == .orderedAscending
    }
  }
}
