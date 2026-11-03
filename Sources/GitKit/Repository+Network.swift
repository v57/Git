import Foundation

// MARK: - Clone, fetch, pull and push

/// Network actions follow the user's `GitSecurityLevel`. On this machine, above `useGit`, the app does them itself
/// through `GitNetwork`'s engine (with this device's vault key or the token, neither of which any process sees) and,
/// where the level lets it, falls back to the `git` command as the user's own setup has it: nothing of the app's in
/// its environment. The local half of a pull or a clone (merge, rebase, checkout) always runs `git`.
extension Repository {
  /// Clones `remote` into `destination`.
  public static func clone(
    _ remote: String, to destination: URL, runner: GitRunner = GitRunner(),
    progress: (@Sendable (String) -> Void)? = nil
  ) async throws -> Repository {
    let parent = destination.deletingLastPathComponent()
    let repository = Repository(url: destination, runner: runner)
    func gitClone(_ remote: String, environment: [String: String]) async throws {
      try await runner.run(
        ["clone", "--progress", "--", remote, destination.path], in: parent, environment: environment, progress: progress)
    }
    let level = await GitNetwork.level()
    if runner.transport != nil, let refusal = level.otherDeviceRefusal { throw GitError(message: refusal) }
    guard runner.transport == nil, level != .useGit, let engine = GitNetwork.engine else {
      let hosts = runner.transport == nil ? nil : Set(GitCredentials.host(ofRemote: remote).map { [$0] } ?? [])
      let sends = runner.transport == nil || level == .useGit
      try await gitClone(remote, environment: sends ? GitCredentials.environment(account: runner.credentialAccount, hosts: hosts) : [:])
      return repository
    }
    // No repository yet: the user's and the system's settings, whatever folder it's going into.
    let settings = GitSetting.parse(try await runner.run(["config", "--list", "-z"], in: nil).output)
    let request = GitNetworkRequest(
      level: level, settings: settings, hasGit: true, sshClientAddress: GitNetwork.configuration?.sshClientAddress,
      progress: progress)
    let outcome = try await GitCredentials.$activeAccount.withValue(runner.credentialAccount) {
      try await engine.clone(remote, to: destination, request: request)
    }
    switch outcome {
    case .done: break
    case .fetched:
      // git's checkout runs the repository's filters, line endings and hooks. An empty repository has nothing to check out.
      if try await repository.hasHead() { try await repository.git(["checkout", "--progress"], progress: progress) }
    case .useGit(_, _, let url, let refusal):
      try await gitClone(url ?? remote, environment: fallbackEnvironment(level))
      if let refusal { throw GitError(message: refusal) }
    }
    return repository
  }

  /// `git` as the user's own setup has it, and at `sshOnly` unable to use anything but SSH (and plain paths, which
  /// aren't the network). Submodules and redirects included: git checks this itself.
  private static func fallbackEnvironment(_ level: GitSecurityLevel) -> [String: String] {
    level == .sshOnly ? ["GIT_ALLOW_PROTOCOL": "ssh:file"] : [:]
  }

  public func fetch(progress: (@Sendable (String) -> Void)? = nil) async throws {
    try await network(.fetch, progress: progress) { remotes in
      remotes.map { ["fetch", "--multiple", "--prune", "--progress"] + $0 } ?? ["fetch", "--all", "--prune", "--progress"]
    }
  }

  /// A pull with the user's pull settings (merge, rebase, ff-only).
  public func pull(progress: (@Sendable (String) -> Void)? = nil) async throws {
    let outcome = try await network(.pull, progress: progress) { _ in ["pull", "--progress"] }
    if outcome == .fetched { try await integrateFetched(progress: progress) }
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
    try await network(.push(force: force), progress: progress) { _ in arguments }
  }

  public func deleteRemoteBranch(_ branch: Branch, progress: (@Sendable (String) -> Void)? = nil)
    async throws
  {
    guard let remote = branch.remoteName else {
      throw GitError(message: "\(branch.name) isn't a remote branch.")
    }
    let ref = "refs/heads/\(branch.localName)"
    do {
      try await network(
        .deleteBranch(name: branch.localName, remote: remote, expected: branch.sha), progress: progress
      ) { _ in ["push", "--progress", "--force-with-lease=\(ref):\(branch.sha)", remote, "--delete", ref] }
    } catch let error as GitError where error.message.contains("(stale info)") {
      throw GitError(
        arguments: error.arguments, exitCode: error.exitCode,
        message: "\(branch.name) has commits you haven't fetched. Fetch, look at them, and try again.")
    }
  }

  /// Moves a remote to its HTTPS address, once git can read from there: a wrong address changes nothing. Git on
  /// another machine gets the account's token for that host from now on: the user just accepted this.
  public func switchToHTTPS(_ remote: HTTPSRemote) async throws {
    let level = await GitNetwork.level()
    if let transport = runner.transport {
      if let refusal = level.otherDeviceRefusal { throw GitError(message: refusal) }
      GitNetwork.acceptToken(forHost: remote.host, device: transport.machineID, path: url.path)
    }
    try await git(
      ["ls-remote", "--", remote.url, "HEAD"], environment: await credentials(forHost: remote.host, level: level))
    try await git(["remote", "set-url", "--", remote.remote, remote.url])
    // A push URL of its own stays otherwise.
    let pushURL = try await output(["remote", "get-url", "--push", "--", remote.remote])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if HTTPSRemote(remote: remote.remote, sshURL: pushURL) != nil {
      try await git(["remote", "set-url", "--push", "--", remote.remote, remote.url])
    }
  }

  /// The environment git runs with for a network command, by level: on this machine the runner's account's token only
  /// at `useGit`. Git on another machine gets only those for a host it's about to talk to (`host`, else its remotes'),
  /// as that machine can read what it's sent, and above `useGit` only the hosts the user accepted the HTTPS offer for.
  private func credentials(forHost host: String? = nil, level: GitSecurityLevel) async -> [String: String] {
    guard let transport = runner.transport else {
      return level == .useGit ? GitCredentials.environment(account: runner.credentialAccount) : [:]
    }
    var hosts: Set<String>
    if let host {
      hosts = [host]
    } else {
      let remotes = (try? await output(["remote", "-v"])) ?? ""
      hosts = Set(
        remotes.split(separator: "\n").compactMap { line -> String? in
          let url = line.split(whereSeparator: \.isWhitespace).dropFirst().first
          return url.flatMap { GitCredentials.host(ofRemote: String($0)) }
        })
    }
    if level != .useGit {
      hosts = hosts.filter { GitNetwork.isTokenAccepted(forHost: $0, device: transport.machineID, path: url.path) }
    }
    return GitCredentials.environment(account: runner.credentialAccount, hosts: hosts)
  }

  /// Runs a network action as the level says. `arguments` is the `git` command for it, given the remotes a fallback is
  /// limited to.
  @discardableResult
  private func network(
    _ action: GitNetworkAction, progress: (@Sendable (String) -> Void)?, arguments: ([String]?) -> [String]
  ) async throws -> GitNetworkOutcome {
    let level = await GitNetwork.level()
    if runner.transport != nil, let refusal = level.otherDeviceRefusal { throw GitError(message: refusal) }
    guard runner.transport == nil, let engine = GitNetwork.engine else {
      try await git(arguments(nil), environment: await credentials(level: runner.transport == nil ? .useGit : level), progress: progress)
      return .done
    }
    if level == .useGit {
      engine.restoreMovedRemotes(in: url)
      try await git(arguments(nil), environment: await credentials(level: level), progress: progress)
      return .done
    }
    let top = try await output(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let settings = GitSetting.parse(try await output(["config", "--list", "-z"]))
    let request = GitNetworkRequest(
      level: level, settings: settings, hasGit: true, sshClientAddress: GitNetwork.configuration?.sshClientAddress,
      progress: progress)
    let outcome = try await GitCredentials.$activeAccount.withValue(runner.credentialAccount) {
      try await engine.perform(action, in: URL(fileURLWithPath: top, isDirectory: true), request: request)
    }
    guard case .useGit(_, let remotes, _, let refusal) = outcome else { return outcome }
    try await git(arguments(remotes), environment: Self.fallbackEnvironment(level), progress: progress)
    if let refusal { throw GitError(message: refusal) }
    return .done
  }

  /// A pull's local half, once the engine fetched: what `git pull` does with `FETCH_HEAD` (or, for a branch tracking a
  /// branch of this repository, its upstream) by the user's `pull.rebase`, `branch.<name>.rebase` and `pull.ff`.
  private func integrateFetched(progress: (@Sendable (String) -> Void)?) async throws {
    func setting(_ key: String) async throws -> String? {
      let value = try await git(["config", "--get", key], allowedExitCodes: [0, 1]).output
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return value.isEmpty ? nil : value
    }
    func isAncestor(_ ancestor: String, of revision: String) async throws -> Bool {
      try await git(["merge-base", "--is-ancestor", ancestor, revision], allowedExitCodes: [0, 1]).exitCode == 0
    }
    let branch = try await output(["symbolic-ref", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let isLocalUpstream = try await setting("branch.\(branch).remote") == "."
    let target = isLocalUpstream ? "@{upstream}" : "FETCH_HEAD"
    let hasHead = try await hasHead()
    if hasHead, try await isAncestor(target, of: "HEAD") { return }
    var rebase = try await setting("branch.\(branch).rebase")
    if rebase == nil { rebase = try await setting("pull.rebase") }
    let ff = try await setting("pull.ff")
    var canFastForward = !hasHead
    if hasHead { canFastForward = try await isAncestor("HEAD", of: target) }
    if let rebase, rebase != "false", rebase != "no", rebase != "off", rebase != "0" {
      var arguments = ["rebase"]
      if rebase == "merges" || rebase == "m" { arguments.append("--rebase-merges") }
      if rebase == "interactive" || rebase == "i" { arguments.append("--interactive") }
      // Without a branch it rebases on the upstream from its fork point, as `git pull --rebase`.
      try await git(arguments, progress: progress)
      return
    }
    var arguments = ["merge", "--no-edit"]
    switch ff {
    case "only":
      guard canFastForward else {
        throw GitError(message: "\(branch) and its upstream have both changed, and pull.ff says to only fast-forward.")
      }
      arguments.append("--ff-only")
    case "false", "no", "off", "0": arguments.append("--no-ff")
    case nil:
      guard canFastForward || rebase != nil else {
        throw GitError(
          message: "\(branch) and its upstream have both changed, and git doesn't know how to bring them together. "
            + "Set pull.rebase or pull.ff: git config pull.rebase false to merge, true to rebase.")
      }
    default: arguments.append("--ff")
    }
    try await git(arguments + [target], progress: progress)
  }

  func pushRemote(for branch: String) async throws -> String {
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
