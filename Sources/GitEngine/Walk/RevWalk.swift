import Foundation

/// A max-heap of commits by committer date; ties pop in insertion order.
struct CommitQueue {
  private var items: [(date: Int, order: Int, id: ObjectID)] = []
  private var counter = 0

  var isEmpty: Bool { items.isEmpty }
  var ids: [ObjectID] { items.map(\.id) }
  /// The date of the commit `pop` returns next.
  var newestDate: Int? { items.first?.date }

  private func before(_ lhs: Int, _ rhs: Int) -> Bool {
    let a = items[lhs]
    let b = items[rhs]
    return a.date != b.date ? a.date > b.date : a.order < b.order
  }

  mutating func push(_ id: ObjectID, date: Int) {
    items.append((date, counter, id))
    counter += 1
    var child = items.count - 1
    while child > 0 {
      let parent = (child - 1) / 2
      guard before(child, parent) else { break }
      items.swapAt(child, parent)
      child = parent
    }
  }

  mutating func pop() -> ObjectID? {
    guard !items.isEmpty else { return nil }
    items.swapAt(0, items.count - 1)
    let top = items.removeLast()
    var parent = 0
    while true {
      let left = parent * 2 + 1
      let right = left + 1
      var best = parent
      if left < items.count, before(left, best) { best = left }
      if right < items.count, before(right, best) { best = right }
      if best == parent { break }
      items.swapAt(parent, best)
      parent = best
    }
    return top.id
  }
}

/// Walks commit history.
enum RevWalk {
  private static func date(_ store: ObjectStore, _ id: ObjectID) throws -> Int {
    Int(try store.commit(id).committer.date.timeIntervalSince1970)
  }

  /// Commits reachable from `tips`, newest first (git log's default order), after skipping `skip`.
  static func log(_ store: ObjectStore, from tips: [ObjectID], skip: Int, limit: Int) throws
    -> [(id: ObjectID, commit: CommitObject)]
  {
    var queue = CommitQueue()
    var seen = Set<ObjectID>()
    for tip in tips where seen.insert(tip).inserted { queue.push(tip, date: try date(store, tip)) }
    var result: [(ObjectID, CommitObject)] = []
    var skipped = 0
    while result.count < limit, let id = queue.pop() {
      let commit = try store.commit(id)
      for parent in commit.parents where seen.insert(parent).inserted {
        // A shallow or incomplete history ends where its commits stop.
        guard let parentDate = try? date(store, parent) else { continue }
        queue.push(parent, date: parentDate)
      }
      if skipped < skip {
        skipped += 1
      } else {
        result.append((id, commit))
      }
    }
    return result
  }

  /// Paints history from both sides until the remaining commits are reachable from both: the commits only `left`
  /// reaches and the ones only `right` reaches.
  static func exclusive(_ store: ObjectStore, left: [ObjectID], right: [ObjectID]) throws
    -> (left: [ObjectID], right: [ObjectID])
  {
    var flags: [ObjectID: UInt8] = [:]
    var queue = CommitQueue()
    func mark(_ id: ObjectID, _ flag: UInt8) throws {
      let old = flags[id] ?? 0
      guard old | flag != old else { return }
      flags[id] = old | flag
      guard let commitDate = try? date(store, id) else { return }
      queue.push(id, date: commitDate)
    }
    for id in left { try mark(id, 1) }
    for id in right { try mark(id, 2) }
    // The oldest commit walked while only one side reached it: a queued commit as old or older may still be its
    // descendant on the other side (commits made in the same second share a date) and has to pass the news on.
    var oldestOneSided = Int.max
    while let date = queue.newestDate, let id = queue.pop() {
      let flag = flags[id] ?? 0
      if flag != 3 { oldestOneSided = min(oldestOneSided, date) }
      for parent in (try? store.commit(id).parents) ?? [] { try mark(parent, flag) }
      // Done when every queued commit is reachable from both sides and newer than none of the one-sided ones.
      if let newest = queue.newestDate, newest < oldestOneSided, queue.ids.allSatisfy({ flags[$0] == 3 }) { break }
    }
    var onlyLeft: [ObjectID] = []
    var onlyRight: [ObjectID] = []
    for (id, flag) in flags {
      if flag == 1 { onlyLeft.append(id) }
      if flag == 2 { onlyRight.append(id) }
    }
    return (onlyLeft, onlyRight)
  }

  /// Commits `a` has that `b` doesn't (ahead) and the reverse (behind).
  static func divergence(_ store: ObjectStore, _ a: ObjectID, _ b: ObjectID) throws -> (ahead: Int, behind: Int) {
    if a == b { return (0, 0) }
    let result = try exclusive(store, left: [a], right: [b])
    return (result.left.count, result.right.count)
  }

  static func isAncestor(_ store: ObjectStore, _ ancestor: ObjectID, of descendant: ObjectID) throws -> Bool {
    if ancestor == descendant { return true }
    return try exclusive(store, left: [ancestor], right: [descendant]).left.isEmpty
  }
}
