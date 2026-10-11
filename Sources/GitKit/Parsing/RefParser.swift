import Foundation

/// Parses `git for-each-ref --format=<RefParser.format>` and `git stash list`.
enum RefParser {
  static let format =
    "%(refname)%00%(objectname)%00%(upstream:short)%00%(upstream:track,nobracket)%00%(HEAD)"
    + "%00%(committerdate:unix)%00%(contents:subject)"

  static func parseBranches(_ output: String) -> [Branch] {
    output.split(separator: "\n").compactMap { line in
      let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
      guard fields.count >= 7 else { return nil }
      let refName = String(fields[0])
      let isRemote = refName.hasPrefix("refs/remotes/")
      let prefix = isRemote ? "refs/remotes/" : "refs/heads/"
      guard refName.hasPrefix(prefix) else { return nil }
      let name = String(refName.dropFirst(prefix.count))
      // origin/HEAD is a symbolic ref to the default branch.
      if isRemote, name.hasSuffix("/HEAD") { return nil }
      let track = String(fields[3])
      return Branch(
        refName: refName, name: name, isRemote: isRemote, isCurrent: fields[4] == "*",
        sha: String(fields[1]), upstream: fields[2].isEmpty ? nil : String(fields[2]),
        ahead: count(in: track, after: "ahead "), behind: count(in: track, after: "behind "),
        isUpstreamGone: track == "gone",
        date: TimeInterval(fields[5]).map(Date.init(timeIntervalSince1970:)),
        subject: fields[6...].joined(separator: " "))
    }
  }

  /// `ahead 2, behind 1` → 2 for "ahead ".
  private static func count(in track: String, after label: String) -> Int {
    guard let range = track.range(of: label) else { return 0 }
    return Int(track[range.upperBound...].prefix { $0.isNumber }) ?? 0
  }

  static let stashFormat = "%gd%x1f%H%x1f%ct%x1f%gs"

  static func parseStashes(_ output: String) -> [Stash] {
    output.split(separator: "\0").compactMap { record in
      let fields = record.split(separator: "\u{1F}", omittingEmptySubsequences: false)
      guard fields.count >= 4 else { return nil }
      let reference = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let index = Int(reference.drop { $0 != "{" }.dropFirst().prefix { $0.isNumber }) ?? 0
      return Stash(
        reference: reference, index: index, sha: String(fields[1]),
        date: Date(timeIntervalSince1970: TimeInterval(fields[2]) ?? 0),
        message: fields[3...].joined(separator: " "))
    }
  }
}
