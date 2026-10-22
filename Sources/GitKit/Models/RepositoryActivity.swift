import Foundation

/// When a repository was last worked on, for sorting and filtering a long list: its last commit, its last push and
/// the newest of its uncommitted changes.
public struct RepositoryActivity: Sendable, Hashable {
  /// HEAD's commit date and subject.
  public var lastCommit: Date?
  public var lastCommitSubject: String?
  /// When the current branch was last pushed to its upstream (from the upstream's reflog, which only knows pushes
  /// from this clone).
  public var lastPush: Date?
  /// The newest modification of an uncommitted change (an untracked folder counts as its own date).
  public var lastChange: Date?

  public init(lastCommit: Date? = nil, lastCommitSubject: String? = nil, lastPush: Date? = nil, lastChange: Date? = nil) {
    self.lastCommit = lastCommit
    self.lastCommitSubject = lastCommitSubject
    self.lastPush = lastPush
    self.lastChange = lastChange
  }

  /// The newest of a change and a commit: what "Recent Changes" sorts by.
  public var lastWorkedOn: Date? {
    [lastChange, lastCommit].compactMap { $0 }.max()
  }
}

extension Repository {
  /// The repository's last commit, push and change, from three cheap git calls and a look at the changed files.
  @concurrent public func activity() async throws -> RepositoryActivity {
    var activity = RepositoryActivity()
    let head = try await git(["log", "-1", "--format=%ct%x00%s", "HEAD"], allowedExitCodes: [0, 128])
    if head.exitCode == 0 {
      let parts = head.output.trimmingCharacters(in: .newlines).split(separator: "\0", maxSplits: 1)
      activity.lastCommit = parts.first.flatMap { TimeInterval($0) }.map(Date.init(timeIntervalSince1970:))
      activity.lastCommitSubject = parts.count > 1 ? String(parts[1]) : nil
    }
    // The upstream's reflog: a push writes "update by push", a fetch "fetch: …".
    let reflog = try await git(
      ["log", "-g", "-n", "200", "--format=%ct%x00%gs", "@{upstream}"], allowedExitCodes: [0, 128],
      environment: ["GIT_OPTIONAL_LOCKS": "0"])
    if reflog.exitCode == 0 {
      activity.lastPush = Self.lastPush(inReflog: reflog.output)
    }
    let status = try await git(
      ["status", "--porcelain=v2", "-z", "--untracked-files=normal"], environment: ["GIT_OPTIONAL_LOCKS": "0"],
      timeout: .seconds(30))
    let parsed = StatusParser.parse(status.output)
    let paths = Set((parsed.staged + parsed.unstaged + parsed.conflicted).map(\.path))
    activity.lastChange = paths.compactMap { path in
      let url = url.appendingPathComponent(path)
      return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }.max()
    return activity
  }

  /// The newest push in `git log -g --format=%ct%x00%gs` output (newest first).
  static func lastPush(inReflog output: String) -> Date? {
    for line in output.split(separator: "\n") {
      let parts = line.split(separator: "\0", maxSplits: 1)
      guard parts.count == 2, parts[1].hasPrefix("update by push"), let seconds = TimeInterval(parts[0]) else {
        continue
      }
      return Date(timeIntervalSince1970: seconds)
    }
    return nil
  }
}
