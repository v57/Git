import Foundation

/// Parses `git status --porcelain=v2 --branch -z`.
enum StatusParser {
  static func parse(_ output: String) -> WorkingTreeStatus {
    var status = WorkingTreeStatus()
    var records = output.split(separator: "\0", omittingEmptySubsequences: false)[...]
    while let record = records.popFirst() {
      guard let type = record.first else { continue }
      switch type {
      case "#":
        parseHeader(record, into: &status)
      case "1":
        // 1 XY sub mH mI mW hH hI path
        let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard fields.count == 9 else { continue }
        add(xy: fields[1], sub: fields[2], path: String(fields[8]), originalPath: nil, to: &status)
      case "2":
        // 2 XY sub mH mI mW hH hI Xscore path NUL origPath
        let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
        let original = records.popFirst().map(String.init)
        guard fields.count == 10 else { continue }
        add(
          xy: fields[1], sub: fields[2], path: String(fields[9]), originalPath: original,
          to: &status)
      case "u":
        // u XY sub m1 m2 m3 mW h1 h2 h3 path
        let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard fields.count == 11 else { continue }
        status.conflicted.append(
          FileChange(
            path: String(fields[10]), kind: .conflicted, area: .conflicted,
            isSubmodule: fields[2].first == "S", conflict: ConflictType(xy: fields[1])))
      case "?":
        let path = String(record.dropFirst(2))
        status.unstaged.append(FileChange(path: path, kind: .untracked, area: .unstaged))
      default:
        continue  // "!" ignored files
      }
    }
    return status
  }

  private static func parseHeader(_ record: Substring, into status: inout WorkingTreeStatus) {
    let parts = record.split(separator: " ", maxSplits: 2)
    guard parts.count == 3 else { return }
    let value = String(parts[2])
    switch parts[1] {
    case "branch.oid": status.headOID = value == "(initial)" ? nil : value
    case "branch.head": status.branch = value == "(detached)" ? nil : value
    case "branch.upstream": status.upstream = value
    case "branch.ab":
      let numbers = value.split(separator: " ")
      if numbers.count == 2 {
        status.ahead = Int(numbers[0].dropFirst()) ?? 0
        status.behind = Int(numbers[1].dropFirst()) ?? 0
      }
    default: break
    }
  }

  private static func add(
    xy: Substring, sub: Substring, path: String, originalPath: String?,
    to status: inout WorkingTreeStatus
  ) {
    let codes = Array(xy)
    guard codes.count == 2 else { return }
    let isSubmodule = sub.first == "S"
    if let kind = ChangeKind(code: codes[0]) {
      status.staged.append(
        FileChange(
          path: path, originalPath: kind == .renamed || kind == .copied ? originalPath : nil,
          kind: kind, area: .staged, isSubmodule: isSubmodule))
    }
    if let kind = ChangeKind(code: codes[1]) {
      status.unstaged.append(
        FileChange(
          path: path, originalPath: kind == .renamed || kind == .copied ? originalPath : nil,
          kind: kind, area: .unstaged, isSubmodule: isSubmodule))
    }
  }
}
