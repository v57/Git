import Foundation
import SwiftData

/// A repository in the sidebar.
@Model final class SavedRepository {
  @Attribute(.unique) var path: String = ""
  var name: String = ""
  /// The folder it was imported from; the sidebar groups by it.
  var group: String = ""
  var addedAt: Date = Date()
  /// When it was last shown in the window, for the Welcome window's Recent list.
  var lastOpenedAt: Date?

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
