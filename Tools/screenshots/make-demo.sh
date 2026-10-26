#!/bin/zsh
# Makes the repositories Git's screenshots (.dev/screenshots.json) open, so the pictures never show anyone's real
# work: Projects/ (atlas with history, branches, tags, a remote and uncommitted changes, plus three smaller ones),
# Merging/ (the same, with atlas stopped in a merge conflict), Worktrees/ and Remotes/.
# Usage: Tools/screenshots/make-demo.sh [folder]   (default .build/screenshots-demo)
set -euo pipefail
root=${0:A:h:h:h}
demo=${1:-$root/.build/screenshots-demo}
rm -rf "$demo"
mkdir -p "$demo"
demo=${demo:A}

# The user's git config (name, hooks, signing) stays out of the demo.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_DATE

typeset -A emails=(
  "Maya Okafor" maya@example.com "Jonas Berg" jonas@example.com
  "Aiko Tanaka" aiko@example.com "Rafael Silva" rafael@example.com
)
day=0
# who "Name": the author of the next commits.
who() { GIT_AUTHOR_NAME=$1 GIT_COMMITTER_NAME=$1 GIT_AUTHOR_EMAIL=$emails[$1] GIT_COMMITTER_EMAIL=$emails[$1] }
# commit "Message": commits everything, a day or so after the previous commit (the last ones are recent).
commit() {
  day=$((day + 1))
  GIT_AUTHOR_DATE=$(date -u -j -v-18d -v+$((day * 26))H +%Y-%m-%dT%H:%M:%SZ)
  GIT_COMMITTER_DATE=$GIT_AUTHOR_DATE
  git add -A && git commit -q -m "$1"
}
write() { mkdir -p ${1:h}; cat > $1 }

atlas() {
  git init -q -b main "$1" && cd "$1"
  who "Maya Okafor"
  write README.md <<'E'
# Atlas

Plan trips, keep them offline and share them with the people you travel with.
E
  write .gitignore <<'E'
.build/
.DS_Store
E
  write Package.swift <<'E'
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
E
  commit "Started Atlas"
  write Sources/Atlas/Trip.swift <<'E'
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

  /// Nights away, at least one.
  public var nights: Int {
    max(1, Calendar.current.dateComponents([.day], from: start, to: end).day ?? 1)
  }
}

public struct Stop: Identifiable, Codable, Hashable, Sendable {
  public var id = UUID()
  public var place: String
  public var latitude: Double
  public var longitude: Double
}
E
  commit "Trip: Added trips and their stops"
  who "Jonas Berg"
  write Sources/Atlas/TripStore.swift <<'E'
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
    let data = try? JSONEncoder().encode(trips)
    try? data?.write(to: url)
  }
}
E
  commit "TripStore: Saved trips as JSON"
  who "Aiko Tanaka"
  write Sources/Atlas/Views/TripList.swift <<'E'
import SwiftUI

struct TripList: View {
  @Environment(TripStore.self) private var store

  var body: some View {
    List(store.trips) { trip in
      VStack(alignment: .leading) {
        Text(trip.name).font(.headline)
        Text("\(trip.nights) nights").foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Trips")
  }
}
E
  commit "Trips: Listed trips with their length"
  write Tests/AtlasTests/TripTests.swift <<'E'
import Foundation
import Testing
@testable import Atlas

@Test func nightsAreAtLeastOne() {
  let now = Date.now
  #expect(Trip(name: "Day out", start: now, end: now).nights == 1)
}
E
  commit "Tests: Covered a trip's nights"
  who "Maya Okafor"
  write Sources/Atlas/Views/MapView.swift <<'E'
import MapKit
import SwiftUI

/// The trip's stops on a map, joined in order.
struct TripMap: View {
  let trip: Trip

  var body: some View {
    Map {
      ForEach(trip.stops) { stop in
        Marker(stop.place, coordinate: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude))
      }
      MapPolyline(coordinates: trip.stops.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
        .stroke(.blue, lineWidth: 3)
    }
  }
}
E
  commit "Map: Showed a trip's stops on a map"
  git tag -a v1.0.0 -m "Atlas 1.0"
  who "Rafael Silva"
  git switch -q -c fix/date-parsing
  perl -0pi -e 's/max\(1, Calendar.current.dateComponents\(\[.day\], from: start, to: end\).day \?\? 1\)/let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: start),\n      to: Calendar.current.startOfDay(for: end)).day ?? 1\n    return max(1, days)/' Sources/Atlas/Trip.swift
  commit "Trip: Counted nights from midnight, so a late check-in isn't a night short"
  cat >> Tests/AtlasTests/TripTests.swift <<'E'

@Test func lateCheckInCountsTheNight() throws {
  let calendar = Calendar.current
  let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 23)))
  let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 9)))
  #expect(Trip(name: "Porto", start: start, end: end).nights == 2)
}
E
  commit "Tests: Covered a late check-in"
  git switch -q main
  who "Jonas Berg"
  perl -0pi -e 's/# Atlas\n/# Atlas\n\n[![Tests](https:\/\/img.shields.io\/badge\/tests-passing-brightgreen)](#)\n/' README.md
  commit "README: Added the tests badge"
  GIT_AUTHOR_DATE=$GIT_COMMITTER_DATE git merge -q --no-ff fix/date-parsing -m "Merged fix/date-parsing"
  who "Aiko Tanaka"
  perl -0pi -e 's/  public var stops: \[Stop\] = \[\]\n/  public var stops: [Stop] = []\n  public var travelers: [String] = []\n/' Sources/Atlas/Trip.swift
  commit "Trip: Added the people on a trip"
  who "Maya Okafor"
  write Sources/Atlas/Sharing.swift <<'E'
import Foundation

/// A trip as a file the other travelers can open.
public struct TripFile: Codable, Sendable {
  public var version = 1
  public var trip: Trip

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self)
  }
}
E
  commit "Sharing: Shared a trip as a file"
  who "Rafael Silva"
  git tag -a v1.1.0 -m "Atlas 1.1"
  git switch -q -c feature/offline-maps
  perl -0pi -e 's/  private func save\(\) \{\n    let data = try\? JSONEncoder\(\).encode\(trips\)\n    try\? data\?.write\(to: url\)\n  \}/  private func save() {\n    let data = try? JSONEncoder().encode(trips)\n    try? data?.write(to: url, options: .atomic)\n    OfflineMaps.shared.prefetch(trips)\n  }/' Sources/Atlas/TripStore.swift
  write Sources/Atlas/OfflineMaps.swift <<'E'
import Foundation

/// Downloads map tiles around each stop, so a trip opens without a connection.
@MainActor
final class OfflineMaps {
  static let shared = OfflineMaps()
  private var pending: Set<UUID> = []

  func prefetch(_ trips: [Trip]) {
    for trip in trips where !pending.contains(trip.id) {
      pending.insert(trip.id)
    }
  }
}
E
  commit "Offline: Prefetched map tiles for every saved trip"
  perl -0pi -e 's/pending.insert\(trip.id\)\n/pending.insert(trip.id)\n      Task { await download(trip) }\n/; s/\n  \}\n\}\n$/\n  }\n\n  private func download(_ trip: Trip) async {\n    defer { pending.remove(trip.id) }\n  }\n}\n/' Sources/Atlas/OfflineMaps.swift
  commit "Offline: Downloaded tiles in the background"
  git switch -q main
  who "Jonas Berg"
  perl -0pi -e 's/  private func save\(\) \{\n    let data = try\? JSONEncoder\(\).encode\(trips\)\n    try\? data\?.write\(to: url\)\n  \}/  private func save() {\n    do {\n      try JSONEncoder().encode(trips).write(to: url, options: [.atomic, .completeFileProtection])\n    } catch {\n      lastError = error\n    }\n  }/; s/  private let url: URL\n/  public private(set) var lastError: Error?\n  private let url: URL\n/' Sources/Atlas/TripStore.swift
  commit "TripStore: Kept the last save error instead of dropping it"
  who "Aiko Tanaka"
  write docs/CHANGELOG.md <<'E'
# Changelog

## 1.2 (unreleased)

- Trips remember why they couldn't be saved.

## 1.1

- Share a trip with the people on it.
- Nights are counted from midnight.
E
  commit "Changelog: Started 1.2"
}

# Puts atlas's remote one commit ahead and two behind, as after a teammate's push.
remote() {
  git clone -q --bare . "$demo/Remotes/atlas.git"
  git remote add origin "$demo/Remotes/atlas.git"
  git fetch -q origin
  git branch -q -u origin/main
  local work=$(mktemp -d)
  git clone -q "$demo/Remotes/atlas.git" "$work/atlas" && (
    cd "$work/atlas"
    git reset -q --hard HEAD~2
    who "Rafael Silva"
    write Sources/Atlas/Views/OpenInMaps.swift <<'E'
import MapKit

extension Stop {
  /// The stop as a Maps item, for "Open in Maps".
  var mapItem: MKMapItem {
    MKMapItem(location: CLLocation(latitude: latitude, longitude: longitude), address: nil)
  }
}
E
    commit "Map: Opened a stop in Maps"
    git push -q -f origin HEAD:main
  )
  rm -rf "$work"
  git fetch -q origin
}

# Edits waiting in Changes: a staged fix, unstaged edits and a new file.
changes() {
  who "Maya Okafor"
  perl -0pi -e 's/Plan trips, keep them offline/Plan trips, keep every map offline/' README.md
  git add README.md
  perl -0pi -e 's/  public func remove\(_ trip: Trip\) \{\n    trips.removeAll \{ \$0.id == trip.id \}\n    save\(\)\n  \}/  public func remove(_ trip: Trip) {\n    trips.removeAll { \$0.id == trip.id }\n    save()\n  }\n\n  \/\/\/ Trips that haven'"'"'t ended, soonest first.\n  public var upcoming: [Trip] {\n    trips.filter { \$0.end >= .now }.sorted { \$0.start < \$1.start }\n  }/; s/  public func add\(_ trip: Trip\) \{\n    trips.append\(trip\)/  public func add(_ trip: Trip) {\n    guard !trips.contains(where: { \$0.id == trip.id }) else { return }\n    trips.append(trip)/' Sources/Atlas/TripStore.swift
  perl -0pi -e 's/Text\("\\\(trip.nights\) nights"\)/Text(trip.start, format: .dateTime.month().day())\n          + Text(" · \\(trip.nights) nights")/' Sources/Atlas/Views/TripList.swift
  write Sources/Atlas/Views/PackingList.swift <<'E'
import SwiftUI

/// What to bring, ticked off as it goes in the bag.
struct PackingList: View {
  @State private var items = ["Passport", "Charger", "Rain jacket", "Adapter"]
  @State private var packed: Set<String> = []

  var body: some View {
    List(items, id: \.self) { item in
      Toggle(item, isOn: Binding(
        get: { packed.contains(item) },
        set: { if $0 { packed.insert(item) } else { packed.remove(item) } }))
    }
    .navigationTitle("Packing")
  }
}
E
}

small() {
  local name=$1 author=$2
  git init -q -b main "$name" && cd "$name"
  who $author
  print "# ${(C)name}" > README.md
  commit "Started ${(C)name}"
  for message in ${@:3}; do
    print -- "- $message" >> README.md
    commit $message
  done
  cd ..
}

others() {
  small beacon "Jonas Berg" "Added the status page" "Checked every service each minute" "Sent alerts to the on-call channel"
  small harbor "Aiko Tanaka" "Added the container list" "Showed each container's logs"
  print -r -- "- Restarts crashed containers" >> harbor/README.md
  small pebble "Rafael Silva" "Added the notes model" "Synced notes over iCloud" "Searched notes by tag" "Pinned notes to the top"
}

mkdir -p "$demo/Projects" "$demo/Merging" "$demo/Worktrees" "$demo/Remotes"

( atlas "$demo/Projects/atlas"
  remote
  git worktree add -q "$demo/Worktrees/atlas-offline-maps" feature/offline-maps
  changes )
( cd "$demo/Projects" && others )

# Merging/atlas: the same history, with feature/offline-maps merged into main and TripStore.swift in conflict.
( atlas "$demo/Merging/atlas"
  who "Maya Okafor"
  git merge -q feature/offline-maps -m "Merged feature/offline-maps" >/dev/null 2>&1 || true )
( cd "$demo/Merging" && others )

print "Screenshot repositories: $demo"
