import Foundation

/// Parses `git log -z --decorate=full --format=<LogParser.format>`.
enum LogParser {
  static let separator: Character = "\u{1F}"
  /// sha, parents, author name/email/date, committer name/email/date, refs, subject, body.
  static let format = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%D%x1f%s%x1f%b"

  static func parse(_ output: String) -> [Commit] {
    output.split(separator: "\0").compactMap(parseRecord)
  }

  private static func parseRecord(_ record: Substring) -> Commit? {
    let fields = record.split(separator: separator, omittingEmptySubsequences: false)
    guard fields.count >= 11 else { return nil }
    // The record may start with a newline left over from the previous record's body.
    let sha = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sha.isEmpty else { return nil }
    return Commit(
      id: sha,
      parents: fields[1].split(separator: " ").map(String.init),
      authorName: String(fields[2]),
      authorEmail: String(fields[3]),
      authorDate: date(fields[4]),
      committerName: String(fields[5]),
      committerEmail: String(fields[6]),
      committerDate: date(fields[7]),
      refs: parseRefs(fields[8]),
      subject: String(fields[9]),
      // A body containing the separator is rejoined rather than truncated.
      body: fields[10...].joined(separator: String(separator))
        .trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func date(_ field: Substring) -> Date {
    Date(timeIntervalSince1970: TimeInterval(field) ?? 0)
  }

  /// `HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1`.
  static func parseRefs(_ field: Substring) -> [RefLabel] {
    guard !field.isEmpty else { return [] }
    var labels: [RefLabel] = []
    for part in field.components(separatedBy: ", ") {
      if part.hasPrefix("HEAD -> ") {
        labels.append(label(for: String(part.dropFirst(8)), isCurrent: true))
      } else if part == "HEAD" {
        labels.append(RefLabel(name: "HEAD", kind: .head, isCurrent: true))
      } else if part.hasPrefix("tag: ") {
        labels.append(label(for: String(part.dropFirst(5)), isCurrent: false))
      } else {
        labels.append(label(for: part, isCurrent: false))
      }
    }
    // refs/remotes/origin/HEAD only repeats the default branch.
    return labels.filter { !($0.kind == .remoteBranch && $0.name.hasSuffix("/HEAD")) }
  }

  private static func label(for ref: String, isCurrent: Bool) -> RefLabel {
    for (prefix, kind) in [
      ("refs/heads/", RefLabel.Kind.localBranch), ("refs/remotes/", .remoteBranch),
      ("refs/tags/", .tag),
    ] where ref.hasPrefix(prefix) {
      return RefLabel(name: String(ref.dropFirst(prefix.count)), kind: kind, isCurrent: isCurrent)
    }
    return RefLabel(name: ref, kind: .other, isCurrent: isCurrent)
  }
}

/// Parses `--name-status -z` output (diff-tree, diff).
enum NameStatusParser {
  static func parse(_ output: String) -> [CommitFile] {
    var fields = output.split(separator: "\0", omittingEmptySubsequences: true)[...]
    var files: [CommitFile] = []
    while let status = fields.popFirst() {
      let code = status.first ?? "M"
      if code == "R" || code == "C" {
        guard let from = fields.popFirst(), let to = fields.popFirst() else { break }
        files.append(
          CommitFile(
            path: String(to), originalPath: String(from), kind: code == "R" ? .renamed : .copied))
      } else {
        guard let path = fields.popFirst() else { break }
        files.append(CommitFile(path: String(path), kind: ChangeKind(code: code) ?? .modified))
      }
    }
    return files
  }
}
