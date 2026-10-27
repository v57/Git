import Foundation

/// A git working tree. Every method runs git in `url` and is safe to call from any task.
public struct Repository: Sendable, Hashable, Identifiable {
  public let url: URL
  let runner: GitRunner

  /// Where git runs: this machine, or another one through `runner.transport`.
  public var isRemote: Bool { runner.transport != nil }

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
    environment: [String: String] = [:], timeout: Duration? = nil,
    progress: (@Sendable (String) -> Void)? = nil
  ) async throws -> GitResult {
    try await runner.run(
      arguments, in: url, input: input, allowedExitCodes: allowedExitCodes,
      environment: environment, timeout: timeout, progress: progress)
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
      in: destination.deletingLastPathComponent(), environment: GitCredentials.environment(),
      progress: progress)
    return Repository(url: destination, runner: runner)
  }
}

// MARK: - Status

extension Repository {
  /// The full status, including every untracked file.
  @concurrent public func status() async throws -> WorkingTreeStatus {
    let result = try await git(
      ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
      environment: ["GIT_OPTIONAL_LOCKS": "0"], timeout: .seconds(60))
    var status = StatusParser.parse(result.output)
    status.operation = try? await operationInProgress()
    return status
  }

  /// A cheap status for lists: branch, ahead/behind and number of changed paths.
  @concurrent public func summary() async throws -> RepositorySummary {
    let result = try await git(
      ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"],
      environment: ["GIT_OPTIONAL_LOCKS": "0"], timeout: .seconds(30))
    var status = StatusParser.parse(result.output)
    status.operation = try? await operationInProgress()
    return RepositorySummary(status)
  }

  /// A merge, rebase, cherry-pick or revert that is waiting to be continued or aborted.
  public func operationInProgress() async throws -> RepositoryOperation? {
    let gitDir = try await gitDirectory()
    func exists(_ name: String) async -> Bool {
      await runner.fileExists(at: gitDir.appendingPathComponent(name))
    }
    if await exists("rebase-merge") { return .rebase }
    if await exists("rebase-apply") { return .rebase }
    if await exists("MERGE_HEAD") { return .merge }
    if await exists("CHERRY_PICK_HEAD") { return .cherryPick }
    if await exists("REVERT_HEAD") { return .revert }
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

  /// What the operation brings in: the merged branch, the picked or reverted commit, or the
  /// branch being rebased.
  public func operationSource(_ operation: RepositoryOperation) async -> String? {
    func name(_ revision: String) async -> String? {
      let result = try? await git(
        ["name-rev", "--name-only", "--no-undefined", "--exclude=refs/tags/*", revision],
        allowedExitCodes: [0, 128])
      guard let result, result.exitCode == 0 else { return nil }
      var name = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
      if name.hasPrefix("remotes/") { name.removeFirst("remotes/".count) }
      return name.isEmpty ? nil : name
    }
    func summary(_ revision: String) async -> String? {
      let output = try? await output(["log", "-1", "--format=%h %s", revision])
      return output?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    switch operation {
    case .merge: return await name("MERGE_HEAD")
    case .cherryPick: return await summary("CHERRY_PICK_HEAD")
    case .revert: return await summary("REVERT_HEAD")
    case .rebase:
      guard let gitDir = try? await gitDirectory() else { return nil }
      for folder in ["rebase-merge", "rebase-apply"] {
        let url = gitDir.appendingPathComponent(folder).appendingPathComponent("head-name")
        if let data = try? await runner.contents(of: url) {
          let ref = String(decoding: data, as: UTF8.self)
          return ref.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "refs/heads/", with: "")
        }
      }
      return nil
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
      case .any:
        // git ANDs --grep with --author, so each field is its own search, merged newest first.
        guard skip == 0 else { return [] }
        var fields: [LogQuery.SearchField] = [.message, .author]
        if search.count >= 4, search.allSatisfy(\.isHexDigit) { fields.append(.sha) }
        var seen = Set<String>()
        var merged: [Commit] = []
        for field in fields {
          var single = query
          single.searchField = field
          for commit in try await log(single, skip: 0, limit: limit) where seen.insert(commit.id).inserted {
            merged.append(commit)
          }
        }
        return merged.sorted { $0.committerDate > $1.committerDate }.prefix(limit).map { $0 }
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
    if query.allBranches, query.revision == nil {
      arguments += ["--branches", "--remotes", "--tags", "HEAD"]
    } else {
      arguments.append(query.revision ?? "HEAD")
    }
    arguments.append("--")
    if let path = query.path { arguments.append(path) }
    return LogParser.parse(try await output(arguments))
  }

  /// Files changed by `commit`, against its first parent.
  @concurrent public func changedFiles(in commit: Commit) async throws -> [CommitFile] {
    let base = try await baseRevision(for: commit)
    async let names = output([
      "diff-tree", "-r", "-z", "-M", "--no-commit-id", "--name-status", base, commit.id,
    ])
    async let numbers = output([
      "diff-tree", "-r", "-z", "-M", "--no-commit-id", "--numstat", base, commit.id,
    ])
    let counts = NumstatParser.parse((try? await numbers) ?? "")
    return NameStatusParser.parse(try await names).map { file in
      var file = file
      file.lines = counts[file.path]
      return file
    }
  }

  /// Lines added and removed per path: staged (index against HEAD) and unstaged (working tree
  /// against the index, plus untracked files counted whole).
  @concurrent public func lineCounts(untracked: [String] = []) async throws
    -> (staged: [String: LineCounts], unstaged: [String: LineCounts])
  {
    let options = ["--numstat", "-z", "--no-ext-diff", "--no-renames"]
    async let staged = hasHead()
      ? output(["diff", "--cached"] + options, environment: ["GIT_OPTIONAL_LOCKS": "0"]) : ""
    async let unstaged = output(["diff"] + options, environment: ["GIT_OPTIONAL_LOCKS": "0"])
    var unstagedCounts = NumstatParser.parse(try await unstaged)
    for path in untracked {
      let url = url.appendingPathComponent(path)
      if runner.transport == nil,
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap({ $0 }).map({ $0 >= 2_000_000 }) ?? true
      {
        continue
      }
      guard let data = try? await runner.contents(of: url), data.count < 2_000_000 else { continue }
      unstagedCounts[path] =
        data.contains(0)
        ? LineCounts(added: nil, removed: nil)
        : LineCounts(added: data.reduce(0) { $1 == 10 ? $0 + 1 : $0 } + (data.last == 10 || data.isEmpty ? 0 : 1), removed: 0)
    }
    return (NumstatParser.parse(try await staged), unstagedCounts)
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
      return try? await runner.contents(of: url.appendingPathComponent(path))
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
  /// - Parameter ignoreWhitespace: hides whitespace-only changes. Such a diff can't be used to
  ///   stage lines, so it reports `supportsLineSelection == false`.
  @concurrent public func diff(_ target: DiffTarget, ignoreWhitespace: Bool = false) async throws
    -> FileDiff?
  {
    let result: GitResult
    let options = Self.diffOptions + (ignoreWhitespace ? ["--ignore-all-space"] : [])
    switch target {
    case .unstaged(let path, true):
      result = try await git(
        ["diff", "--no-index"] + options + ["--", "/dev/null", path],
        allowedExitCodes: [0, 1])
    case .unstaged(let path, false):
      result = try await git(["diff"] + options + ["--", path])
    case .staged(let path, let originalPath):
      let paths = [originalPath, path].compactMap { $0 }
      result = try await git(["diff", "--cached", "-M"] + options + ["--"] + paths)
    case .commit(let sha, let parent, let path, let originalPath):
      let base: String
      if let parent { base = parent } else { base = try await emptyTree() }
      let paths = [originalPath, path].compactMap { $0 }
      result = try await git(["diff", "-M"] + options + [base, sha, "--"] + paths)
    }
    var diffs = DiffParser.parse(result.stdout)
    if ignoreWhitespace {
      for index in diffs.indices { diffs[index].ignoresWhitespace = true }
    }
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
      try await runner.discard(url.appendingPathComponent(change.path))
    }
  }

  /// Throws away staged changes along with the same files' working-tree changes: the files are
  /// unstaged, then discarded, so files new in the index are moved to the Trash.
  public func discardStaged(_ changes: [FileChange]) async throws {
    let paths = Set(changes.flatMap { [$0.originalPath, $0.path].compactMap { $0 } })
    try await unstage(paths.sorted())
    let unstaged = try await status().unstaged.filter { paths.contains($0.path) }
    try await discard(unstaged)
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
  /// Each branch also carries its divergence from HEAD when HEAD has a commit.
  @concurrent public func branches() async throws -> [Branch] {
    let format = try await hasHead() ? RefParser.formatWithDivergence : RefParser.format
    let arguments = ["for-each-ref", "--sort=refname", "refs/heads", "refs/remotes"]
    do {
      return RefParser.parseBranches(try await output(arguments + ["--format=\(format)"]))
    } catch where format == RefParser.formatWithDivergence {
      // git before 2.41 has no %(ahead-behind).
      return RefParser.parseBranches(try await output(arguments + ["--format=\(RefParser.format)"]))
    }
  }

  /// Every worktree of the repository, the main one first.
  @concurrent public func worktrees() async throws -> [Worktree] {
    RefParser.parseWorktrees(
      try await output(["worktree", "list", "--porcelain", "-z"]), current: url)
  }

  /// Creates a tag at `revision` (HEAD when `nil`), annotated when `message` is given.
  public func createTag(_ name: String, at revision: String? = nil, message: String? = nil)
    async throws
  {
    var arguments = ["tag"]
    if let message, !message.isEmpty { arguments += ["--annotate", "--message", message] }
    arguments.append(name)
    if let revision { arguments.append(revision) }
    try await git(arguments)
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

  /// Merges `branch` into the current branch. Conflicts leave a merge in progress.
  public func merge(_ branch: Branch) async throws {
    try await git(["merge", "--no-edit", branch.name])
  }

  /// Tags, highest version first (`v2.10` before `v2.9`).
  @concurrent public func tags() async throws -> [Tag] {
    TagParser.parse(
      try await output(["for-each-ref", "--sort=-v:refname", "refs/tags", "--format=\(TagParser.format)"]))
  }

  /// Checks out `commit` without a branch (detached HEAD).
  public func checkout(_ commit: Commit) async throws {
    try await git(["switch", "--detach", commit.id])
  }

  /// Applies `commit` on top of HEAD (against its first parent for a merge). Conflicts leave a
  /// cherry-pick in progress.
  public func cherryPick(_ commit: Commit) async throws {
    var arguments = ["cherry-pick"]
    if commit.isMerge { arguments += ["-m", "1"] }
    try await git(arguments + [commit.id])
  }

  /// Whether `name` is a valid tag name.
  public func isValidTagName(_ name: String) async -> Bool {
    guard !name.isEmpty else { return false }
    let result = try? await git(
      ["check-ref-format", "refs/tags/\(name)"], allowedExitCodes: [0, 1, 128])
    return result?.exitCode == 0
  }

  /// Whether `name` is a valid new branch name.
  public func isValidBranchName(_ name: String) async -> Bool {
    guard !name.isEmpty else { return false }
    let result = try? await git(
      ["check-ref-format", "--branch", name], allowedExitCodes: [0, 1, 128])
    return result?.exitCode == 0
  }
}

// MARK: - Rewriting

extension Repository {
  public enum ResetMode: String, Sendable { case soft, mixed, hard }

  /// Creates a commit that undoes `commit` (against its first parent for a merge). Conflicts
  /// leave a revert in progress.
  public func revert(_ commit: Commit) async throws {
    var arguments = ["revert", "--no-edit"]
    if commit.isMerge { arguments += ["-m", "1"] }
    try await git(arguments + [commit.id])
  }

  /// Moves the current branch to `revision`. `mixed` keeps the changes in the working tree.
  public func reset(to revision: String, mode: ResetMode = .mixed) async throws {
    try await git(["reset", "--\(mode.rawValue)", "-q", revision])
  }

  /// Removes the last commit but keeps its changes staged, and returns its message. The first
  /// commit is undone by deleting the branch ref, which leaves an unborn branch.
  @discardableResult
  public func undoLastCommit() async throws -> String {
    let message = try await lastCommitMessage()
    let hasParent = try await git(
      ["rev-parse", "--verify", "--quiet", "HEAD~1"], allowedExitCodes: [0, 1]
    ).exitCode == 0
    if hasParent {
      try await git(["reset", "--soft", "HEAD~1"])
    } else {
      try await git(["update-ref", "-d", "HEAD"])
    }
    return message
  }

  /// Replaces `commits`, which must follow one another on HEAD's history, with one commit that
  /// has their combined changes, the oldest one's author and `message`, and returns it.
  ///
  /// Later commits on HEAD are recreated on top with the same trees, so the working tree and
  /// index stay as they are and nothing can conflict. HEAD moves only if it hasn't moved since.
  /// Like `git commit`, the new commits are signed when `commit.gpgSign` is set.
  @discardableResult
  public func squash(_ commits: [Commit], message: String) async throws -> String {
    let run = try Commit.squashRun(commits).map(\.id)
    let newest = run[0]
    let oldest = run[run.count - 1]
    if try await operationInProgress() != nil {
      throw GitError(message: "Continue or abort the operation in progress first.")
    }
    let head = try await output(["rev-parse", "--verify", "HEAD"])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let isOnHead = try await git(
      ["merge-base", "--is-ancestor", newest, head], allowedExitCodes: [0, 1]
    ).exitCode == 0
    guard isOnHead else { throw GitError.squashOffHead }

    // Commits after the run, parents first.
    let later = try await output([
      "rev-list", "--reverse", "--topo-order", "--ancestry-path", "\(newest)..\(head)",
    ]).split(separator: "\n").map(String.init)
    // A branch merged into HEAD that starts inside the run would bring the old commits back.
    let descendants = try await output([
      "rev-list", "--count", "--ancestry-path", "\(oldest)..\(head)",
    ]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(descendants) == later.count + run.count - 1 else {
      throw GitError(
        message: "A branch merged into this one starts from one of these commits, so they "
          + "can't be squashed.")
    }

    let records = try await commitRecords(run + later)
    for (index, id) in run.enumerated() {
      let parents = records[id]?.parents ?? []
      let expected = index + 1 < run.count ? [run[index + 1]] : Array(parents.prefix(1))
      guard parents == expected else {
        throw GitError(message: "Only commits that follow one another can be squashed.")
      }
    }
    let squashedMessage = try await git(["stripspace"], input: Data(message.utf8)).stdout
    guard !squashedMessage.isEmpty, let base = records[oldest], let tip = records[newest] else {
      throw GitError(message: "Enter a message for the squashed commit.")
    }

    let sign = try await git(
      ["config", "--type=bool", "--get", "commit.gpgsign"], allowedExitCodes: [0, 1]
    ).output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    func commitTree(_ tree: String, parents: [String], author: CommitRecord, message: Data)
      async throws -> String
    {
      let arguments =
        ["commit-tree"] + (sign ? ["-S"] : []) + parents.flatMap { ["-p", $0] } + ["-F", "-", tree]
      let environment = [
        "GIT_AUTHOR_NAME": author.authorName, "GIT_AUTHOR_EMAIL": author.authorEmail,
        "GIT_AUTHOR_DATE": author.authorDate,
      ]
      return try await git(arguments, input: message, environment: environment).output
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var rewritten: [String: String] = [:]
    rewritten[newest] = try await commitTree(
      tip.tree, parents: base.parents, author: base, message: squashedMessage)
    for id in later {
      guard let record = records[id] else {
        throw GitError(message: "Couldn't read commit \(id.prefix(7)).")
      }
      rewritten[id] = try await commitTree(
        record.tree, parents: record.parents.map { rewritten[$0] ?? $0 }, author: record,
        message: Data(record.message.utf8))
    }
    guard let squashed = rewritten[newest], let newHead = rewritten[head] else {
      throw GitError(message: "Couldn't squash the commits.")
    }
    let subject = String(decoding: squashedMessage, as: UTF8.self)
      .prefix { $0 != "\n" }
    try await git(["update-ref", "-m", "squash: \(subject)", "HEAD", newHead, head])
    return squashed
  }

  /// What recreating a commit needs, read as git stores it: the raw author date and message.
  struct CommitRecord {
    var tree: String
    var parents: [String]
    var authorName: String
    var authorEmail: String
    var authorDate: String
    var message: String
  }

  private func commitRecords(_ ids: [String]) async throws -> [String: CommitRecord] {
    let format = ["%H", "%T", "%P", "%an", "%ae", "%ad", "%B"].joined(separator: "%x1f")
    let output = try await git(
      ["log", "--no-walk=unsorted", "--stdin", "-z", "--date=raw", "--format=\(format)"],
      input: Data((ids.joined(separator: "\n") + "\n").utf8)
    ).output
    var records: [String: CommitRecord] = [:]
    for record in output.split(separator: "\0") {
      let fields = record.split(separator: "\u{1f}", maxSplits: 6, omittingEmptySubsequences: false)
        .map(String.init)
      guard fields.count == 7 else { continue }
      records[fields[0]] = CommitRecord(
        tree: fields[1], parents: fields[2].split(separator: " ").map(String.init),
        authorName: fields[3], authorEmail: fields[4], authorDate: fields[5], message: fields[6])
    }
    return records
  }

  /// Commits on HEAD that aren't on its upstream (or, without one, on any remote).
  @concurrent public func unpushedCommits(limit: Int = 1000) async throws -> Set<String> {
    guard try await hasHead() else { return [] }
    let upstream = try await git(
      ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
      allowedExitCodes: [0, 128])
    let range = upstream.exitCode == 0 ? ["@{upstream}..HEAD"] : ["HEAD", "--not", "--remotes"]
    let output = try await output(["rev-list", "--max-count=\(limit)"] + range)
    return Set(output.split(separator: "\n").map(String.init))
  }

  /// When the repository last fetched (the modification date of FETCH_HEAD).
  public func lastFetchDate() async -> Date? {
    guard let gitDir = try? await gitDirectory() else { return nil }
    let values = try? gitDir.appendingPathComponent("FETCH_HEAD")
      .resourceValues(forKeys: [.contentModificationDateKey])
    return values?.contentModificationDate
  }
}

// MARK: - Remotes

extension Repository {
  public func remotes() async throws -> [String] {
    try await output(["remote"]).split(separator: "\n").map(String.init)
  }

  /// The URL `remote` fetches from.
  public func remoteURL(_ remote: String) async throws -> String {
    try await output(["remote", "get-url", "--", remote])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func addRemote(_ name: String, url: String) async throws {
    try await git(["remote", "add", "--", name, url])
  }

  public func fetch(progress: (@Sendable (String) -> Void)? = nil) async throws {
    try await git(
      ["fetch", "--all", "--prune", "--progress"], environment: GitCredentials.environment(),
      progress: progress)
  }

  /// `git pull` with the user's pull settings (merge, rebase, ff-only).
  public func pull(progress: (@Sendable (String) -> Void)? = nil) async throws {
    try await git(["pull", "--progress"], environment: GitCredentials.environment(), progress: progress)
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
    try await git(arguments, environment: GitCredentials.environment(), progress: progress)
  }

  public func deleteRemoteBranch(_ branch: Branch, progress: (@Sendable (String) -> Void)? = nil)
    async throws
  {
    guard let remote = branch.remoteName else {
      throw GitError(message: "\(branch.name) isn't a remote branch.")
    }
    let ref = "refs/heads/\(branch.localName)"
    do {
      try await git(
        ["push", "--progress", "--force-with-lease=\(ref):\(branch.sha)", remote, "--delete", ref],
        progress: progress)
    } catch let error as GitError where error.message.contains("(stale info)") {
      throw GitError(
        arguments: error.arguments, exitCode: error.exitCode,
        message: "\(branch.name) has commits you haven't fetched. Fetch, look at them, and try again.")
    }
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

// MARK: - Conflicts

extension Repository {
  /// The working-tree text of a conflicted file split into blocks, or `nil` when it has no
  /// conflict markers (binary, deleted, or already edited by hand).
  @concurrent public func conflictedFile(_ path: String) async throws -> ConflictedFile? {
    guard let data = try await runner.contents(of: url.appendingPathComponent(path)) else { return nil }
    guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
    return ConflictParser.parse(text)
  }

  /// Writes the resolved `text` to `path` and marks it resolved. The file keeps its permissions.
  public func resolveConflict(_ path: String, with text: String) async throws {
    try await runner.write(Data(text.utf8), to: url.appendingPathComponent(path))
    try await markResolved([path])
  }

  /// Resolves `path` with one side's whole version. When that side deleted the file, the file is
  /// deleted.
  public func resolveConflict(_ path: String, taking side: ConflictSide) async throws {
    // Stage 2 is the current side, stage 3 the incoming one.
    let stage = side == .current ? "2" : "3"
    let stages = try await output(["ls-files", "-u", "-z", "--", path])
      .split(separator: "\0")
      .compactMap { $0.split(separator: "\t").first?.split(separator: " ").last }
    if stages.contains(where: { $0 == stage }) {
      try await git(["checkout", side == .current ? "--ours" : "--theirs", "--", path])
      try await git(["add", "--", path])
    } else {
      try await git(["rm", "--quiet", "--ignore-unmatch", "--", path])
    }
  }
}

// MARK: - Ignoring

extension Repository {
  /// The `.gitignore` lines that ignore `path`: the file itself, every file with its extension and
  /// each folder it sits in, the closest folder first. Paths are anchored at the root (`/build/`)
  /// and escaped, so they match only what they name.
  public static func ignorePatterns(for path: String) -> IgnorePatterns {
    let components = path.split(separator: "/").map(String.init)
    let folders = components.dropLast().indices.reversed().map { end in
      "/" + components[...end].map(escapeIgnored).joined(separator: "/") + "/"
    }
    let name = components.last ?? path
    // A dot that starts the name (`.env`) doesn't start an extension.
    let dot = name.lastIndex(of: ".").flatMap { $0 > name.startIndex ? $0 : nil }
    let ext = dot.map { String(name[name.index(after: $0)...]) } ?? ""
    return IgnorePatterns(
      file: "/" + components.map(escapeIgnored).joined(separator: "/"),
      fileExtension: ext.isEmpty ? nil : "*." + escapeIgnored(ext),
      folders: folders)
  }

  private static func escapeIgnored(_ component: String) -> String {
    var escaped = ""
    for character in component {
      if "\\*?[".contains(character) { escaped.append("\\") }
      escaped.append(character)
    }
    if escaped.hasSuffix(" ") { escaped.insert("\\", at: escaped.index(before: escaped.endIndex)) }
    return escaped
  }

  /// Adds `pattern` to the `.gitignore` at the root unless it already has that line, then stops
  /// tracking the files it ignores (they stay on disk), since git keeps tracking ignored files.
  public func ignore(_ pattern: String) async throws {
    let file = url.appendingPathComponent(".gitignore")
    let existing = try await runner.contents(of: file)
    var text = existing.map { String(decoding: $0, as: UTF8.self) } ?? ""
    let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    if !lines.contains(pattern) {
      if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
      text += pattern + "\n"
      if existing == nil, runner.transport == nil {
        try text.write(to: file, atomically: true, encoding: .utf8)
      } else {
        try await runner.write(Data(text.utf8), to: file)
      }
    }
    let tracked = try await git(["ls-files", "-z", "--cached", "--ignored", "--exclude=\(pattern)"]).stdout
    if !tracked.isEmpty {
      try await git(
        ["rm", "--cached", "-f", "-q", "--pathspec-from-file=-", "--pathspec-file-nul"], input: tracked)
    }
  }
}

/// The ways to ignore one changed file (`Repository.ignorePatterns(for:)`).
public struct IgnorePatterns: Sendable, Hashable {
  /// The file itself, as `/docs/notes.txt`.
  public var file: String
  /// Every file with its extension, as `*.txt`; `nil` for a name without one.
  public var fileExtension: String?
  /// The folders that hold it, the closest first, as `/docs/`.
  public var folders: [String]
}
