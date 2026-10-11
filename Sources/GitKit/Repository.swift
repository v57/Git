import Foundation

/// A git working tree. Every method runs git in `url` and is safe to call from any task.
public struct Repository: Sendable, Hashable, Identifiable {
  public let url: URL
  let runner: GitRunner

  public init(url: URL, runner: GitRunner = GitRunner()) {
    self.url = url.standardizedFileURL
    self.runner = runner
  }

  public var id: URL { url }
  public var name: String { url.lastPathComponent }

  public static func == (lhs: Repository, rhs: Repository) -> Bool { lhs.url == rhs.url }
  public func hash(into hasher: inout Hasher) { hasher.combine(url) }

  /// Runs `git <arguments>` in the working tree.
  @discardableResult
  public func git(
    _ arguments: [String], input: Data? = nil, allowedExitCodes: Set<Int32> = [0],
    environment: [String: String] = [:], progress: (@Sendable (String) -> Void)? = nil
  ) async throws -> GitResult {
    try await runner.run(
      arguments, in: url, input: input, allowedExitCodes: allowedExitCodes,
      environment: environment, progress: progress)
  }

  /// stdout of `git <arguments>` as a string.
  func output(_ arguments: [String], environment: [String: String] = [:]) async throws -> String {
    try await git(arguments, environment: environment).output
  }

  /// The absolute `.git` directory (a file-backed one for worktrees and submodules).
  public func gitDirectory() async throws -> URL {
    let path = try await output(["rev-parse", "--absolute-git-dir"])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  /// Creates a repository with `git init`.
  public static func initialize(at url: URL, runner: GitRunner = GitRunner()) async throws
    -> Repository
  {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try await runner.run(["init"], in: url)
    return Repository(url: url, runner: runner)
  }

  /// Clones `remote` into `destination`.
  public static func clone(
    _ remote: String, to destination: URL, runner: GitRunner = GitRunner(),
    progress: (@Sendable (String) -> Void)? = nil
  ) async throws -> Repository {
    try await runner.run(
      ["clone", "--progress", "--", remote, destination.path],
      in: destination.deletingLastPathComponent(), progress: progress)
    return Repository(url: destination, runner: runner)
  }
}

// MARK: - Status

extension Repository {
  /// The full status, including every untracked file.
  @concurrent public func status() async throws -> WorkingTreeStatus {
    let result = try await git(
      ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
      environment: ["GIT_OPTIONAL_LOCKS": "0"])
    var status = StatusParser.parse(result.output)
    status.operation = try? await operationInProgress()
    return status
  }

  /// A cheap status for lists: branch, ahead/behind and number of changed paths.
  @concurrent public func summary() async throws -> RepositorySummary {
    let result = try await git(
      ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"],
      environment: ["GIT_OPTIONAL_LOCKS": "0"])
    return RepositorySummary(StatusParser.parse(result.output))
  }

  /// A merge, rebase, cherry-pick or revert that is waiting to be continued or aborted.
  public func operationInProgress() async throws -> RepositoryOperation? {
    let gitDir = try await gitDirectory()
    let fm = FileManager.default
    func exists(_ name: String) -> Bool {
      fm.fileExists(atPath: gitDir.appendingPathComponent(name).path)
    }
    if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
    if exists("MERGE_HEAD") { return .merge }
    if exists("CHERRY_PICK_HEAD") { return .cherryPick }
    if exists("REVERT_HEAD") { return .revert }
    return nil
  }

  /// `git <operation> --continue`, or `commit` for a merge (which needs a commit to finish).
  public func continueOperation(_ operation: RepositoryOperation) async throws {
    switch operation {
    case .merge: try await git(["commit", "--no-edit"])
    case .rebase: try await git(["rebase", "--continue"])
    case .cherryPick: try await git(["cherry-pick", "--continue"])
    case .revert: try await git(["revert", "--continue"])
    }
  }

  public func abortOperation(_ operation: RepositoryOperation) async throws {
    switch operation {
    case .merge: try await git(["merge", "--abort"])
    case .rebase: try await git(["rebase", "--abort"])
    case .cherryPick: try await git(["cherry-pick", "--abort"])
    case .revert: try await git(["revert", "--abort"])
    }
  }
}

// MARK: - History

extension Repository {
  /// A page of commits, newest first.
  @concurrent public func log(_ query: LogQuery = LogQuery(), skip: Int = 0, limit: Int = 200) async throws
    -> [Commit]
  {
    var arguments = [
      "log", "-z", "--decorate=full", "--format=\(LogParser.format)", "--skip=\(skip)",
      "--max-count=\(limit)",
    ]
    if let search = query.search?.trimmingCharacters(in: .whitespaces), !search.isEmpty {
      switch query.searchField {
      case .message: arguments += ["--regexp-ignore-case", "--fixed-strings", "--grep=\(search)"]
      case .author: arguments += ["--regexp-ignore-case", "--fixed-strings", "--author=\(search)"]
      case .sha:
        // A sha prefix resolves to at most one commit.
        guard search.allSatisfy(\.isHexDigit), skip == 0,
          let sha = try? await output(["rev-parse", "--verify", "--quiet", "\(search)^{commit}"])
            .trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty
        else { return [] }
        arguments += ["--max-count=1", sha]
        return LogParser.parse(try await output(arguments + ["--"]))
      }
    }
    if query.revision == nil, !(try await hasHead()) { return [] }
    arguments.append(query.revision ?? "HEAD")
    arguments.append("--")
    if let path = query.path { arguments.append(path) }
    return LogParser.parse(try await output(arguments))
  }

  /// Files changed by `commit`, against its first parent.
  @concurrent public func changedFiles(in commit: Commit) async throws -> [CommitFile] {
    let base = try await baseRevision(for: commit)
    let output = try await output([
      "diff-tree", "-r", "-z", "-M", "--no-commit-id", "--name-status", base, commit.id,
    ])
    return NameStatusParser.parse(output)
  }

  /// The commit's first parent, or the empty tree for a root commit.
  func baseRevision(for commit: Commit) async throws -> String {
    if let parent = commit.parents.first { return parent }
    return try await emptyTree()
  }

  func emptyTree() async throws -> String {
    try await git(["hash-object", "-t", "tree", "--stdin"], input: Data()).output
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The message of HEAD, for amending.
  public func lastCommitMessage() async throws -> String {
    try await output(["log", "-1", "--format=%B"]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Contents of `path` at `revision`, or `nil` when it does not exist there.
  @concurrent public func contents(of path: String, at revision: FileRevision) async -> Data? {
    switch revision {
    case .workingTree:
      return try? Data(contentsOf: url.appendingPathComponent(path))
    case .index:
      return try? await git(["show", ":\(path)"]).stdout
    case .commit(let sha):
      return try? await git(["show", "\(sha):\(path)"]).stdout
    }
  }
}

// MARK: - Diff

extension Repository {
  static let diffOptions = ["--no-ext-diff", "--no-color", "-U3", "--submodule=short"]

  /// The diff of one file, or `nil` when it has no changes.
  @concurrent public func diff(_ target: DiffTarget) async throws -> FileDiff? {
    let result: GitResult
    switch target {
    case .unstaged(let path, true):
      result = try await git(
        ["diff", "--no-index"] + Self.diffOptions + ["--", "/dev/null", path],
        allowedExitCodes: [0, 1])
    case .unstaged(let path, false):
      result = try await git(["diff"] + Self.diffOptions + ["--", path])
    case .staged(let path, let originalPath):
      let paths = [originalPath, path].compactMap { $0 }
      result = try await git(["diff", "--cached", "-M"] + Self.diffOptions + ["--"] + paths)
    case .commit(let sha, let parent, let path, let originalPath):
      let base: String
      if let parent { base = parent } else { base = try await emptyTree() }
      let paths = [originalPath, path].compactMap { $0 }
      result = try await git(["diff", "-M"] + Self.diffOptions + [base, sha, "--"] + paths)
    }
    let diffs = DiffParser.parse(result.stdout)
    return diffs.first { $0.path == target.path } ?? diffs.first
  }
}

// MARK: - Staging

extension Repository {
  public func stage(_ paths: [String]) async throws {
    guard !paths.isEmpty else { return }
    try await git(["add", "-A", "--"] + paths)
  }

  public func stageAll() async throws {
    try await git(["add", "-A"])
  }

  public func unstage(_ paths: [String]) async throws {
    guard !paths.isEmpty else { return }
    if try await hasHead() {
      try await git(["restore", "--staged", "--"] + paths)
    } else {
      try await git(["rm", "--cached", "-r", "-q", "--"] + paths)
    }
  }

  public func unstageAll() async throws {
    if try await hasHead() {
      try await git(["reset", "-q"])
    } else {
      try await git(["rm", "--cached", "-r", "-q", "."])
    }
  }

  /// Throws away working-tree changes. Tracked files are restored from the index; untracked
  /// files are moved to the Trash, so nothing is lost for good.
  public func discard(_ changes: [FileChange]) async throws {
    let untracked = changes.filter { $0.kind == .untracked }
    let tracked = changes.filter { $0.kind != .untracked }.map(\.path)
    if !tracked.isEmpty {
      try await git(["restore", "--worktree", "--"] + tracked)
    }
    for change in untracked {
      try FileManager.default.trashItem(
        at: url.appendingPathComponent(change.path), resultingItemURL: nil)
    }
  }

  /// Stages the `lines` of an unstaged diff.
  public func stageLines(_ lines: Set<Int>, of diff: FileDiff) async throws {
    try await apply(diff, lines: lines, direction: .forward, arguments: ["--cached"])
  }

  /// Unstages the `lines` of a staged diff.
  public func unstageLines(_ lines: Set<Int>, of diff: FileDiff) async throws {
    try await apply(diff, lines: lines, direction: .reverse, arguments: ["--cached", "--reverse"])
  }

  /// Discards the `lines` of an unstaged diff from the working tree.
  public func discardLines(_ lines: Set<Int>, of diff: FileDiff) async throws {
    try await apply(diff, lines: lines, direction: .reverse, arguments: ["--reverse"])
  }

  private func apply(
    _ diff: FileDiff, lines: Set<Int>, direction: PatchBuilder.Direction, arguments: [String]
  ) async throws {
    guard diff.supportsLineSelection else {
      throw GitError(message: "Lines of \(diff.path) can't be selected individually.")
    }
    guard let patch = PatchBuilder.patch(for: diff, selecting: lines, direction: direction) else {
      return
    }
    try await git(
      ["apply", "--recount", "--whitespace=nowarn"] + arguments + ["-"], input: Data(patch.utf8))
  }

  /// Marks conflicted files as resolved.
  public func markResolved(_ paths: [String]) async throws {
    try await stage(paths)
  }

  func hasHead() async throws -> Bool {
    let result = try await git(
      ["rev-parse", "--verify", "--quiet", "HEAD"], allowedExitCodes: [0, 1])
    return result.exitCode == 0
  }
}

// MARK: - Commit

extension Repository {
  /// Commits the index. Hooks and commit signing run as configured.
  @discardableResult
  public func commit(message: String, amend: Bool = false) async throws -> String {
    var arguments = ["commit", "--file=-", "--cleanup=strip"]
    if amend { arguments.append("--amend") }
    try await git(arguments, input: Data(message.utf8))
    return try await output(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// MARK: - Branches

extension Repository {
  /// Local branches, then remote-tracking branches, each sorted by name.
  @concurrent public func branches() async throws -> [Branch] {
    let output = try await output([
      "for-each-ref", "--format=\(RefParser.format)", "--sort=refname", "refs/heads",
      "refs/remotes",
    ])
    return RefParser.parseBranches(output)
  }

  /// Checks out a local branch, or creates a tracking branch for a remote one.
  public func switchTo(_ branch: Branch) async throws {
    if branch.isRemote {
      let local = branch.localName
      let exists = try await git(
        ["show-ref", "--verify", "--quiet", "refs/heads/\(local)"], allowedExitCodes: [0, 1]
      ).exitCode == 0
      if exists {
        try await git(["switch", local])
      } else {
        try await git(["switch", "--track", branch.name])
      }
    } else {
      try await git(["switch", branch.name])
    }
  }

  /// Creates `name` at `startPoint` (HEAD when `nil`) and optionally checks it out.
  public func createBranch(_ name: String, from startPoint: String? = nil, checkout: Bool = true)
    async throws
  {
    let start = startPoint.map { [$0] } ?? []
    if checkout {
      try await git(["switch", "-c", name] + start)
    } else {
      try await git(["branch", name] + start)
    }
  }

  public func deleteBranch(_ name: String, force: Bool = false) async throws {
    try await git(["branch", force ? "-D" : "-d", name])
  }

  /// Whether `name` is a valid new branch name.
  public func isValidBranchName(_ name: String) async -> Bool {
    guard !name.isEmpty else { return false }
    let result = try? await git(
      ["check-ref-format", "--branch", name], allowedExitCodes: [0, 1, 128])
    return result?.exitCode == 0
  }
}

// MARK: - Remotes

extension Repository {
  public func remotes() async throws -> [String] {
    try await output(["remote"]).split(separator: "\n").map(String.init)
  }

  public func fetch(progress: (@Sendable (String) -> Void)? = nil) async throws {
    try await git(["fetch", "--all", "--prune", "--progress"], progress: progress)
  }

  /// `git pull` with the user's pull settings (merge, rebase, ff-only).
  public func pull(progress: (@Sendable (String) -> Void)? = nil) async throws {
    try await git(["pull", "--progress"], progress: progress)
  }

  /// Pushes the current branch. A branch without an upstream is pushed to its push remote (or
  /// `origin`, or the only remote) and starts tracking it.
  public func push(force: Bool = false, progress: (@Sendable (String) -> Void)? = nil)
    async throws
  {
    let status = try await status()
    guard let branch = status.branch else {
      throw GitError(message: "HEAD is detached. Switch to a branch before pushing.")
    }
    var arguments = ["push", "--progress"]
    if force { arguments.append("--force-with-lease") }
    if status.upstream == nil {
      let remote = try await pushRemote(for: branch)
      arguments += ["--set-upstream", remote, "HEAD"]
    }
    try await git(arguments, progress: progress)
  }

  private func pushRemote(for branch: String) async throws -> String {
    for key in ["branch.\(branch).pushRemote", "remote.pushDefault", "branch.\(branch).remote"] {
      let value = try await git(["config", "--get", key], allowedExitCodes: [0, 1]).output
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { return value }
    }
    let remotes = try await remotes()
    if remotes.contains("origin") { return "origin" }
    if remotes.count == 1 { return remotes[0] }
    if remotes.isEmpty { throw GitError(message: "This repository has no remote to push to.") }
    throw GitError(
      message: "Several remotes and none is the default. Set one with "
        + "git config remote.pushDefault <remote>.")
  }
}

// MARK: - Stash

extension Repository {
  @concurrent public func stashes() async throws -> [Stash] {
    RefParser.parseStashes(try await output(["stash", "list", "-z", "--format=\(RefParser.stashFormat)"]))
  }

  /// Stashes working-tree and index changes, including untracked files by default.
  public func stash(message: String? = nil, includeUntracked: Bool = true) async throws {
    var arguments = ["stash", "push"]
    if includeUntracked { arguments.append("--include-untracked") }
    if let message, !message.isEmpty { arguments += ["--message", message] }
    try await git(arguments)
  }

  public func applyStash(_ stash: Stash) async throws {
    try await git(["stash", "apply", stash.reference])
  }

  public func popStash(_ stash: Stash) async throws {
    try await git(["stash", "pop", stash.reference])
  }

  public func dropStash(_ stash: Stash) async throws {
    try await git(["stash", "drop", stash.reference])
  }
}
