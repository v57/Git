import ComponentKit
import GitKit
import SwiftUI
import VaultKit

/// How a repository on another device was when Git there last looked (the vault's `VaultProject.Status`), under the
/// screen that connects to it: "Last seen on Studio Mac: 3 changes on main", then its first few files. Shown while it
/// connects and when it can't.
public struct LastSeenChanges: View {
  let device: String
  let status: VaultProject.Status
  /// When the device wrote it, for its age ("2 hr. ago"); nil when the vault doesn't say.
  var date: Date?
  /// How many files it lists before "and N more".
  var limit = 6

  public init(device: String, status: VaultProject.Status, date: Date? = nil, limit: Int = 6) {
    self.device = device
    self.status = status
    self.date = date
    self.limit = limit
  }

  public var body: some View {
    let files = status.files.prefix(limit)
    VStack(alignment: .leading, spacing: 6) {
      Text(date.map { "Last seen on \(device) \(LastSeenAge.text($0)): \(glance)" } ?? "Last seen on \(device): \(glance)")
        .kitFont(.caption)
        .foregroundStyle(.kitSecondary)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(Array(files.enumerated()), id: \.offset) { _, file in
        HStack(spacing: 6) {
          ChangeKindBadge(kind: ChangeKind(letter: file.kind) ?? .modified, size: 16)
          Text((file.path as NSString).lastPathComponent)
            .kitFont(.callout)
            .lineLimit(1)
          let folder = (file.path as NSString).deletingLastPathComponent
          if !folder.isEmpty {
            Text(folder)
              .kitFont(.caption)
              .foregroundStyle(.kitTertiary)
              .lineLimit(1)
              .truncationMode(.head)
          }
        }
      }
      let more = status.changeCount - files.count
      if !files.isEmpty, more > 0 {
        Text(more == 1 ? "and 1 more" : "and \(more) more")
          .kitFont(.caption)
          .foregroundStyle(.kitTertiary)
      }
    }
    // A width of its own: the empty state lays its detail out at its ideal width.
    .frame(width: 300, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  /// "3 changes on main, 1 to push".
  private var glance: String {
    let changes =
      status.changeCount == 0
      ? String(localized: "no changes")
      : status.changeCount == 1 ? String(localized: "1 change") : String(localized: "\(status.changeCount) changes")
    let branch = status.branch ?? String(localized: "a detached HEAD")
    var parts = [String(localized: "\(changes) on \(branch)")]
    if let operation = status.operation.flatMap(RepositoryOperation.init(rawValue:)) {
      parts.append(operation.title.lowercased())
    }
    if status.ahead > 0 { parts.append(String(localized: "\(status.ahead) to push")) }
    if status.behind > 0 { parts.append(String(localized: "\(status.behind) to pull")) }
    return parts.joined(separator: ", ")
  }
}

/// How old a device's last status is: "2 hr. ago", "just now" (G-008: the marks only change when that device's Git
/// writes them, so they say when that was).
public enum LastSeenAge {
  public static func text(_ date: Date, now: Date = .now) -> String {
    if now.timeIntervalSince(date) < 60 { return String(localized: "just now") }
    return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
  }
}
