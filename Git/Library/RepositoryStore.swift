import Foundation
import SQLite3
import SwiftData

/// Builds the app's one SwiftData container for the saved repositories.
enum RepositoryStore {
  /// `~/Library/Application Support/dev.v57.git/Repositories.store`. Without a sandbox, SwiftData's
  /// default configuration stores at `~/Library/Application Support/default.store`, a file every
  /// unsandboxed app that omits a URL shares, so the app pins its own.
  static let url = URL.applicationSupportDirectory
    .appendingPathComponent("dev.v57.git", isDirectory: true)
    .appendingPathComponent("Repositories.store")

  /// The container. Debug builds launched with `--in-memory` keep the repositories in memory, so
  /// scripted runs with `--add-folder` don't change the real list. An unwritable or corrupt store
  /// falls back to memory too, so the app still opens.
  static func makeContainer() -> ModelContainer {
    let schema = Schema([SavedRepository.self, SavedGroup.self])
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--in-memory") {
        return inMemoryContainer(schema)
      }
    #endif
    let folder = url.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch { NSLog("[RepositoryStore] cannot create %@: %@", folder.path, error as NSError) }

    let isNew = !FileManager.default.fileExists(atPath: url.path)
    let disk = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
    let container: ModelContainer
    do {
      container = try ModelContainer(for: schema, configurations: [disk])
    } catch {
      NSLog("[RepositoryStore] disk container failed, falling back to memory: %@", error as NSError)
      return inMemoryContainer(schema)
    }
    if isNew { migrateLegacyRows(into: container) }
    return container
  }

  private static func inMemoryContainer(_ schema: Schema) -> ModelContainer {
    let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try! ModelContainer(for: schema, configurations: [memory])
  }

  // MARK: - Migration from default.store

  /// One-time import: builds before the pinned URL stored their rows in the shared
  /// `default.store`. Copies the `SavedRepository` rows only, since the file can hold other apps'
  /// tables, and leaves `default.store` untouched.
  private static func migrateLegacyRows(into container: ModelContainer) {
    let rows = legacyRows()
    guard !rows.isEmpty else { return }
    let context = ModelContext(container)
    for row in rows {
      context.insert(SavedRepository(path: row.path, group: row.group, addedAt: row.addedAt))
    }
    do {
      try context.save()
      NSLog("[RepositoryStore] migrated %d repositories from default.store", rows.count)
    } catch {
      NSLog("[RepositoryStore] migrating default.store failed: %@", error as NSError)
    }
  }

  /// The `SavedRepository` rows in `default.store`, read straight from SQLite with a read-only
  /// handle: opening a store that other apps share with a SwiftData container could migrate it.
  private static func legacyRows() -> [(path: String, group: String, addedAt: Date)] {
    let legacy = URL.applicationSupportDirectory.appendingPathComponent("default.store")
    guard FileManager.default.fileExists(atPath: legacy.path) else { return [] }

    var handle: OpaquePointer?
    defer { sqlite3_close(handle) }
    guard sqlite3_open_v2(legacy.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      return []
    }
    sqlite3_exec(handle, "PRAGMA busy_timeout = 5000", nil, nil, nil)

    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    // Fails to prepare when the table doesn't exist, i.e. the store isn't (also) ours.
    let sql = "SELECT ZPATH, ZGROUP, ZADDEDAT FROM ZSAVEDREPOSITORY WHERE ZPATH IS NOT NULL"
    guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

    var rows: [(path: String, group: String, addedAt: Date)] = []
    var seen = Set<String>()
    while sqlite3_step(stmt) == SQLITE_ROW {
      let path = String(cString: sqlite3_column_text(stmt, 0))
      guard !path.isEmpty, seen.insert(path).inserted else { continue }
      let group = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
      // Core Data stores dates as seconds since the reference date.
      let addedAt =
        sqlite3_column_type(stmt, 2) == SQLITE_NULL
        ? Date() : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
      rows.append((path, group, addedAt))
    }
    return rows
  }
}
