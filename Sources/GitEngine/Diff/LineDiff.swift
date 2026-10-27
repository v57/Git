import Foundation

/// A file's lines, each with its `\n` (the last may lack one), for diffing.
struct Lines {
  let data: Data
  /// Ranges into `data`, newline included.
  let ranges: [Range<Int>]
  let endsWithoutNewline: Bool

  init(_ data: Data) {
    self.data = data
    var ranges: [Range<Int>] = []
    data.withUnsafeBytes { buffer in
      var start = 0
      for index in 0..<buffer.count where buffer[index] == 0x0A {
        ranges.append(start..<index + 1)
        start = index + 1
      }
      if start < buffer.count { ranges.append(start..<buffer.count) }
    }
    self.ranges = ranges
    endsWithoutNewline = !data.isEmpty && data.last != 0x0A
  }

  var count: Int { ranges.count }

  /// The line's text without its newline (a `\r` stays).
  func text(_ index: Int) -> String {
    var range = ranges[index]
    if data[data.startIndex + range.upperBound - 1] == 0x0A { range = range.lowerBound..<range.upperBound - 1 }
    let start = data.startIndex
    return String(decoding: data[(start + range.lowerBound)..<(start + range.upperBound)], as: UTF8.self)
  }

  func bytes(_ index: Int) -> Data {
    data[(data.startIndex + ranges[index].lowerBound)..<(data.startIndex + ranges[index].upperBound)]
  }
}

/// One run of changed lines: `oldCount` lines at `oldStart` replaced by `newCount` lines at `newStart` (0-based).
struct LineChange: Equatable {
  var oldStart: Int
  var oldCount: Int
  var newStart: Int
  var newCount: Int
}

/// Myers' diff in linear space, with git's (xdiff's) sliding of change groups so ambiguous changes land where git
/// puts them.
enum LineDiff {
  static func changes(_ old: Lines, _ new: Lines) -> [LineChange] {
    // Lines become numbers so comparisons are cheap.
    var numbers: [Data: Int] = [:]
    func number(_ lines: Lines) -> [Int] {
      (0..<lines.count).map { index in
        let bytes = lines.bytes(index)
        if let existing = numbers[bytes] { return existing }
        numbers[bytes] = numbers.count
        return numbers.count - 1
      }
    }
    let a = number(old)
    let b = number(new)
    return changes(a, b)
  }

  static func changes(_ a: [Int], _ b: [Int]) -> [LineChange] {
    var removed = [Bool](repeating: false, count: a.count + 1)
    var added = [Bool](repeating: false, count: b.count + 1)
    var myers = Myers(a: a, b: b)
    myers.diff(0, a.count, 0, b.count, &removed, &added)
    compact(&removed, a, other: &added)
    compact(&added, b, other: &removed)
    var result: [LineChange] = []
    var i = 0
    var j = 0
    while i < a.count || j < b.count {
      if removed[i] || added[j] {
        let start = (i, j)
        while i < a.count && removed[i] { i += 1 }
        while j < b.count && added[j] { j += 1 }
        result.append(LineChange(oldStart: start.0, oldCount: i - start.0, newStart: start.1, newCount: j - start.1))
      } else {
        i += 1
        j += 1
      }
    }
    return result
  }

  private struct Myers {
    let a: [Int]
    let b: [Int]
    var forward: [Int] = []
    var backward: [Int] = []

    init(a: [Int], b: [Int]) {
      self.a = a
      self.b = b
      let size = 2 * (a.count + b.count) + 3
      forward = [Int](repeating: 0, count: size)
      backward = [Int](repeating: 0, count: size)
    }

    mutating func diff(
      _ aLow: Int, _ aHigh: Int, _ bLow: Int, _ bHigh: Int, _ removed: inout [Bool], _ added: inout [Bool]
    ) {
      var aLow = aLow
      var bLow = bLow
      var aHigh = aHigh
      var bHigh = bHigh
      while aLow < aHigh && bLow < bHigh && a[aLow] == b[bLow] {
        aLow += 1
        bLow += 1
      }
      while aLow < aHigh && bLow < bHigh && a[aHigh - 1] == b[bHigh - 1] {
        aHigh -= 1
        bHigh -= 1
      }
      if aLow == aHigh {
        for index in bLow..<bHigh { added[index] = true }
        return
      }
      if bLow == bHigh {
        for index in aLow..<aHigh { removed[index] = true }
        return
      }
      let (startX, startY, endX, endY) = middleSnake(aLow, aHigh, bLow, bHigh)
      diff(aLow, startX, bLow, startY, &removed, &added)
      diff(endX, aHigh, endY, bHigh, &removed, &added)
    }

    /// The middle snake of the shortest edit script: its start and end points.
    private mutating func middleSnake(_ aLow: Int, _ aHigh: Int, _ bLow: Int, _ bHigh: Int) -> (Int, Int, Int, Int) {
      let n = aHigh - aLow
      let m = bHigh - bLow
      let delta = n - m
      let odd = delta & 1 != 0
      let limit = (n + m + 1) / 2
      let offset = limit + 1
      forward[offset + 1] = 0
      backward[offset + 1] = 0
      for d in 0...limit {
        for k in stride(from: -d, through: d, by: 2) {
          var x =
            k == -d || (k != d && forward[offset + k - 1] < forward[offset + k + 1])
            ? forward[offset + k + 1] : forward[offset + k - 1] + 1
          var y = x - k
          let (x0, y0) = (x, y)
          while x < n && y < m && a[aLow + x] == b[bLow + y] {
            x += 1
            y += 1
          }
          forward[offset + k] = x
          let reverseK = delta - k
          if odd, reverseK >= -(d - 1), reverseK <= d - 1, x + backward[offset + reverseK] >= n {
            return (aLow + x0, bLow + y0, aLow + x, bLow + y)
          }
        }
        for k in stride(from: -d, through: d, by: 2) {
          var x =
            k == -d || (k != d && backward[offset + k - 1] < backward[offset + k + 1])
            ? backward[offset + k + 1] : backward[offset + k - 1] + 1
          var y = x - k
          let (x0, y0) = (x, y)
          while x < n && y < m && a[aHigh - 1 - x] == b[bHigh - 1 - y] {
            x += 1
            y += 1
          }
          backward[offset + k] = x
          let forwardK = delta - k
          if !odd, forwardK >= -d, forwardK <= d, x + forward[offset + forwardK] >= n {
            return (aHigh - x, bHigh - y, aHigh - x0, bHigh - y0)
          }
        }
      }
      // Unreachable for a non-empty difference; split in the middle to stay safe.
      return (aLow + n / 2, bLow + m / 2, aLow + n / 2, bLow + m / 2)
    }
  }

  /// xdiff's `xdl_change_compact` without the indent heuristic: each group of changed lines slides as far down as
  /// it can, or to line up with a group in the other file.
  private static func compact(_ changed: inout [Bool], _ lines: [Int], other: inout [Bool]) {
    let count = lines.count
    let otherCount = other.count - 1
    struct Group {
      var start = 0
      var end = 0
    }
    func initial(_ flags: [Bool]) -> Group {
      var group = Group()
      while flags[group.end] { group.end += 1 }
      return group
    }
    func next(_ group: inout Group, _ flags: [Bool], _ total: Int) -> Bool {
      guard group.end < total else { return false }
      group.start = group.end + 1
      group.end = group.start
      while flags[group.end] { group.end += 1 }
      return true
    }
    func previous(_ group: inout Group, _ flags: [Bool]) -> Bool {
      guard group.start > 0 else { return false }
      group.end = group.start - 1
      group.start = group.end
      while group.start > 0 && flags[group.start - 1] { group.start -= 1 }
      return true
    }
    func slideDown(_ group: inout Group) -> Bool {
      guard group.end < count, lines[group.start] == lines[group.end] else { return false }
      changed[group.start] = false
      group.start += 1
      changed[group.end] = true
      group.end += 1
      while changed[group.end] { group.end += 1 }
      return true
    }
    func slideUp(_ group: inout Group) -> Bool {
      guard group.start > 0, lines[group.start - 1] == lines[group.end - 1] else { return false }
      group.start -= 1
      changed[group.start] = true
      group.end -= 1
      changed[group.end] = false
      while group.start > 0 && changed[group.start - 1] { group.start -= 1 }
      return true
    }

    var group = initial(changed)
    var otherGroup = initial(other)
    while true {
      if group.end != group.start {
        var size = 0
        var endMatchingOther = -1
        var earliestEnd = 0
        repeat {
          size = group.end - group.start
          endMatchingOther = -1
          while slideUp(&group) { _ = previous(&otherGroup, other) }
          earliestEnd = group.end
          if otherGroup.end > otherGroup.start { endMatchingOther = group.end }
          while slideDown(&group) {
            _ = next(&otherGroup, other, otherCount)
            if otherGroup.end > otherGroup.start { endMatchingOther = group.end }
          }
        } while size != group.end - group.start
        if group.end != earliestEnd, endMatchingOther != -1 {
          while otherGroup.end == otherGroup.start {
            guard slideUp(&group) else { break }
            _ = previous(&otherGroup, other)
          }
        }
      }
      guard next(&group, changed, count) else { break }
      _ = next(&otherGroup, other, otherCount)
    }
  }
}
