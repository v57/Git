import Foundation
import SwiftData

/// A repository in the sidebar.
@Model final class SavedRepository {
  @Attribute(.unique) var path: String = ""
  var name: String = ""
  /// The folder it was imported from.
  var group: String = ""
  var addedAt: Date = Date()
  /// When it was last shown in the window, for the Welcome window's Recent list.
  var lastOpenedAt: Date?
  /// The `SavedGroup` it was in before the groups moved to the vault (`moveSavedGroupsToVault`).
  var groupID: UUID?
  /// Its place among its group's repositories or the top-level items, before the vault.
  var sortIndex: Int = 0
  /// Hidden from the sidebar until Show Hidden.
  var isHidden: Bool = false
  /// The vault account whose window lists it (`VaultAccount.id`); nil for Personal, as before accounts.
  var accountID: String?

  init(path: String, group: String, addedAt: Date = .now) {
    self.path = path
    self.name = (path as NSString).lastPathComponent
    self.group = group
    self.addedAt = addedAt
  }

  var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
  var groupName: String { (group as NSString).lastPathComponent }
  var exists: Bool {
    FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
  }
}

/// A sidebar group from before the groups moved to the vault (`VaultProjectGroup`, which nest); read
/// once by `moveSavedGroupsToVault` and deleted.
@Model final class SavedGroup {
  @Attribute(.unique) var id: UUID = UUID()
  var name: String = ""
  /// A secondary label, e.g. the folder above an imported group's folder.
  var note: String = ""
  /// The folder an imported group was made from; empty for groups made by hand.
  var directory: String = ""
  /// Its place among the top-level items.
  var sortIndex: Int = 0
  var isCollapsed: Bool = false

  init(name: String, note: String = "", directory: String = "", sortIndex: Int = 0) {
    self.name = name
    self.note = note
    self.directory = directory
    self.sortIndex = sortIndex
  }
}
