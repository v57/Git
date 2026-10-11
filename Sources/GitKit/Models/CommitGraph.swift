import Foundation

/// One history row's part of the branch graph. Lanes are columns; each lane carries the line
/// of one commit that is further down the list.
public struct GraphRow: Sendable, Hashable {
  public struct Edge: Sendable, Hashable {
    public var lane: Int
    /// A color index that stays the same along a line.
    public var color: Int
  }

  public struct Join: Sendable, Hashable {
    public var lane: Int
    public var target: Int
    public var color: Int
  }

  /// The commit's lane.
  public var column: Int
  public var color: Int
  /// Lines from the top edge into the commit, from its children.
  public var incoming: [Edge]
  /// Lines from the commit to the bottom edge, towards its parents.
  public var outgoing: [Edge]
  /// Lines that pass the row from top to bottom.
  public var passing: [Edge]
  /// Lines that enter at the top in `lane` and leave at the bottom in `target`, where a side
  /// lane folds back into the commit's lane.
  public var joining: [Join]
  /// The number of lanes the row uses.
  public var width: Int
}

/// Lays out the branch graph for commits listed children-first, as `git log` lists them.
public enum CommitGraph {
  public static func layout(_ commits: [Commit]) -> [GraphRow] {
    // The commit each lane waits for, and the lane's color.
    var lanes: [String?] = []
    var colors: [Int] = []
    var nextColor = 0
    var rows: [GraphRow] = []
    rows.reserveCapacity(commits.count)

    func freeLane() -> Int {
      if let index = lanes.firstIndex(where: { $0 == nil }) { return index }
      lanes.append(nil)
      colors.append(0)
      return lanes.count - 1
    }

    for commit in commits {
      let before = lanes
      let waiting = lanes.indices.filter { lanes[$0] == commit.id }
      let incoming = waiting.map { GraphRow.Edge(lane: $0, color: colors[$0]) }
      for lane in waiting { lanes[lane] = nil }

      // A branch tip nothing above points to starts a new lane.
      let column: Int
      if let first = waiting.first {
        column = first
      } else {
        column = freeLane()
        colors[column] = nextColor
        nextColor += 1
      }
      let color = colors[column]

      var outgoing: [GraphRow.Edge] = []
      var joining: [GraphRow.Join] = []
      for (index, parent) in commit.parents.enumerated() {
        if index == 0, let existing = lanes.firstIndex(where: { $0 == parent }), existing > column {
          // A lane to the right already leads to the first parent: fold it into this one, so
          // the line keeps to the left.
          joining.append(GraphRow.Join(lane: existing, target: column, color: colors[existing]))
          lanes[existing] = nil
          lanes[column] = parent
          outgoing.append(GraphRow.Edge(lane: column, color: color))
        } else if let existing = lanes.firstIndex(where: { $0 == parent }) {
          // Another lane already leads to this parent: join it.
          outgoing.append(GraphRow.Edge(lane: existing, color: colors[existing]))
        } else if index == 0 {
          lanes[column] = parent
          outgoing.append(GraphRow.Edge(lane: column, color: color))
        } else {
          let lane = freeLane()
          lanes[lane] = parent
          colors[lane] = nextColor
          nextColor += 1
          outgoing.append(GraphRow.Edge(lane: lane, color: colors[lane]))
        }
      }

      let passing = before.indices.compactMap { lane -> GraphRow.Edge? in
        guard let id = before[lane], id != commit.id, lane < lanes.count, lanes[lane] == id else {
          return nil
        }
        return GraphRow.Edge(lane: lane, color: colors[lane])
      }
      while lanes.last == .some(nil) {
        lanes.removeLast()
        colors.removeLast()
      }
      rows.append(
        GraphRow(
          column: column, color: color, incoming: incoming, outgoing: outgoing, passing: passing,
          joining: joining, width: max(before.count, lanes.count, column + 1)))
    }
    return rows
  }
}
