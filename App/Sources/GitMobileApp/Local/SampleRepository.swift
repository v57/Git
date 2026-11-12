import Foundation
import GitEngine
import GitKit

/// A made-up repository to try Git with on this device, with no server, account or Mac (App Review, TestFlight, a
/// first look): Atlas, a small Swift package with a history by four people, a branch with work of its own and two
/// changes left uncommitted, so History, Branches, Changes, the diff, staging and committing all have something to
/// show. Built here by GitEngine (nothing is downloaded), offered on the welcome and in On This iPhone's Add menu, and
/// deleted like any other repository.
enum SampleRepository {
  static let name = "Atlas Sample"

  /// Makes a sample repository and hands its id to `select`, which opens it.
  static func open(select: @escaping (RepositorySource.ID) -> Void) {
    Task {
      guard let repository = try? await LocalRepositories.shared.createSample() else { return }
      select(RepositorySource.local(repository).id)
    }
  }

  /// Makes the sample in `folder`, which mustn't exist yet. A failed run leaves no folder behind.
  static func create(at folder: URL) async throws -> LocalRepository {
    do {
      let repository = try LocalRepository.initialize(at: folder)
      for (index, step) in history.enumerated() {
        if let branch = step.branch { try await repository.createBranch(branch) }
        if let back = step.switchTo {
          guard let branch = try await repository.branches().first(where: { $0.name == back && !$0.isRemote }) else {
            throw CocoaError(.fileNoSuchFile)
          }
          try await repository.switchTo(branch)
        }
        guard let message = step.message else { continue }
        try write(step.files, in: folder)
        try await repository.stageAll()
        let author = authors[step.author]
        let date = start.addingTimeInterval(Double(index) * 86_400 * 1.6)
        _ = try await repository.commit(
          message: message, author: GitSignature(name: author.name, email: author.email, date: date))
      }
      // Left for the reviewer: one file changed and one new, so Changes has something to stage and commit.
      try write(uncommitted, in: folder)
      return repository
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
  }

  private static func write(_ files: [String: String], in folder: URL) throws {
    for (path, text) in files {
      let url = folder.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
  }

  private static let start = Date(timeIntervalSince1970: 1_788_220_800)  // 2026-09-01 00:00 UTC

  private static let authors: [(name: String, email: String)] = [
    ("Maya Okafor", "maya@example.com"), ("Jonas Berg", "jonas@example.com"), ("Aiko Tanaka", "aiko@example.com"),
    ("Rafael Silva", "rafael@example.com"),
  ]

  /// One commit, or a branch made or left before it.
  private struct Step {
    var author = 0
    var message: String?
    var files: [String: String] = [:]
    /// Created at HEAD and switched to before this step's commit.
    var branch: String?
    /// Switched back to before this step's commit.
    var switchTo: String?
  }

  private static let history: [Step] = [
    Step(author: 0, message: "Started Atlas", files: [
      "README.md": readme, ".gitignore": ".build/\n.DS_Store\n", "Package.swift": package,
    ]),
    Step(author: 0, message: "Trip: Added trips and their stops", files: ["Sources/Atlas/Trip.swift": trip]),
    Step(author: 1, message: "TripStore: Kept trips on the device as JSON", files: ["Sources/Atlas/TripStore.swift": store]),
    Step(author: 2, message: "Tests: Covered adding and removing trips", files: ["Tests/AtlasTests/TripStoreTests.swift": tests]),
    Step(author: 1, message: "TripStore: Sorted trips by their start date", files: ["Sources/Atlas/TripStore.swift": sortedStore]),
    Step(author: 3, message: "README: Explained the modules and how to start", files: ["README.md": longReadme]),
    Step(
      author: 2, message: "Maps: Sketched the offline tile cache", files: ["Sources/Atlas/MapCache.swift": cache],
      branch: "feature/offline-maps"),
    Step(author: 2, message: "Maps: Capped the cache at 200 MB", files: ["Sources/Atlas/MapCache.swift": cappedCache]),
    Step(switchTo: "main"),
    Step(author: 0, message: "Trip: Counted nights, at least one", files: ["Sources/Atlas/Trip.swift": tripWithNights]),
  ]

  private static let uncommitted: [String: String] = [
    "Sources/Atlas/TripStore.swift": sortedStore.replacingOccurrences(
      of: "  public func remove(_ trip: Trip) {",
      with: """
          /// The trips that haven't ended yet.
          public var upcoming: [Trip] { trips.filter { $0.end >= .now } }

          public func remove(_ trip: Trip) {
        """),
    "NOTES.md": "# Notes\n\n- Ask Jonas about the map cache size on older phones\n- Share a trip as a link?\n",
  ]

  private static let readme = """
    # Atlas

    Plan trips, keep them offline and share them with the people you travel with.

    """

  private static let longReadme = """
    # Atlas

    Plan trips, keep them offline and share them with the people you travel with.

    ## Modules

    | Module | What it does |
    |--------|--------------|
    | `Trip` | A trip and its stops |
    | `TripStore` | The trips on this device |

    ## Getting started

    ```swift
    let store = TripStore(url: .documentsDirectory.appending(path: "trips.json"))
    store.add(Trip(name: "Lisbon", start: .now, end: .now.addingTimeInterval(4 * 86_400)))
    ```

    """

  private static let package = """
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
      name: "Atlas",
      platforms: [.iOS(.v18), .macOS(.v15)],
      products: [.library(name: "Atlas", targets: ["Atlas"])],
      targets: [
        .target(name: "Atlas"),
        .testTarget(name: "AtlasTests", dependencies: ["Atlas"]),
      ]
    )

    """

  private static let trip = """
    import Foundation

    /// A trip: where, when, and the stops along the way.
    public struct Trip: Identifiable, Codable, Hashable, Sendable {
      public var id = UUID()
      public var name: String
      public var start: Date
      public var end: Date
      public var stops: [Stop] = []

      public init(name: String, start: Date, end: Date) {
        self.name = name
        self.start = start
        self.end = end
      }
    }

    public struct Stop: Identifiable, Codable, Hashable, Sendable {
      public var id = UUID()
      public var place: String
      public var latitude: Double
      public var longitude: Double
    }

    """

  private static let tripWithNights = trip.replacingOccurrences(
    of: """
        self.end = end
      }
    }
    """,
    with: """
        self.end = end
      }

      /// Nights away, at least one.
      public var nights: Int {
        max(1, Calendar.current.dateComponents([.day], from: start, to: end).day ?? 1)
      }
    }
    """)

  private static let store = """
    import Foundation
    import Observation

    /// The trips on this device, saved as JSON.
    @MainActor @Observable
    public final class TripStore {
      public private(set) var trips: [Trip] = []
      private let url: URL

      public init(url: URL) {
        self.url = url
        load()
      }

      public func add(_ trip: Trip) {
        trips.append(trip)
        save()
      }

      public func remove(_ trip: Trip) {
        trips.removeAll { $0.id == trip.id }
        save()
      }

      private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        trips = (try? JSONDecoder().decode([Trip].self, from: data)) ?? []
      }

      private func save() {
        try? JSONEncoder().encode(trips).write(to: url, options: .atomic)
      }
    }

    """

  private static let sortedStore = store.replacingOccurrences(
    of: """
        trips.append(trip)
        save()
    """,
    with: """
        trips.append(trip)
        trips.sort { $0.start < $1.start }
        save()
    """)

  private static let tests = """
    import Foundation
    import Testing
    @testable import Atlas

    @MainActor struct TripStoreTests {
      @Test func addsAndRemovesTrips() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = TripStore(url: url)
        let trip = Trip(name: "Lisbon", start: .now, end: .now.addingTimeInterval(4 * 86_400))
        store.add(trip)
        #expect(TripStore(url: url).trips == [trip])
        store.remove(trip)
        #expect(TripStore(url: url).trips.isEmpty)
      }
    }

    """

  private static let cache = """
    import Foundation

    /// Map tiles kept on the device, so a trip's maps work without a connection.
    actor MapCache {
      private let folder: URL

      init(folder: URL) {
        self.folder = folder
      }

      func tile(x: Int, y: Int, zoom: Int) -> Data? {
        try? Data(contentsOf: url(x: x, y: y, zoom: zoom))
      }

      func store(_ data: Data, x: Int, y: Int, zoom: Int) throws {
        try data.write(to: url(x: x, y: y, zoom: zoom))
      }

      private func url(x: Int, y: Int, zoom: Int) -> URL {
        folder.appending(path: "\\(zoom)-\\(x)-\\(y).png")
      }
    }

    """

  private static let cappedCache = cache.replacingOccurrences(
    of: """
      func store(_ data: Data, x: Int, y: Int, zoom: Int) throws {
        try data.write(to: url(x: x, y: y, zoom: zoom))
      }
    """,
    with: """
      /// The most the cache keeps; the oldest tiles go first.
      static let limit = 200 * 1024 * 1024

      func store(_ data: Data, x: Int, y: Int, zoom: Int) throws {
        try data.write(to: url(x: x, y: y, zoom: zoom))
        try trim()
      }

      private func trim() throws {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)
          .map { ($0, try $0.resourceValues(forKeys: Set(keys))) }
          .sorted { ($0.1.contentModificationDate ?? .distantPast) < ($1.1.contentModificationDate ?? .distantPast) }
        var total = files.reduce(0) { $0 + ($1.1.fileSize ?? 0) }
        for (url, values) in files where total > Self.limit {
          try FileManager.default.removeItem(at: url)
          total -= values.fileSize ?? 0
        }
      }
    """)
}
