import Foundation
import GitKit
import Testing

@testable import GitEngine

/// `Repository`'s network actions at each security level, with real git for the fallback: `ssh` stands in as a script
/// that runs the service here, and leaves a note that it ran and what environment it had.
@Suite struct SecurityLevelTests {
  struct Scene {
    let served: ServedRepository
    let sshRan: URL
    let environmentFile: URL
    let runner: GitRunner

    init() throws {
      served = try ServedRepository()
      sshRan = served.fixture.sibling("ssh-ran")
      environmentFile = served.fixture.sibling("environment")
      let script = served.fixture.sibling("fake-ssh")
      try Data(
        """
        #!/bin/sh
        touch '\(sshRan.path)'
        env > '\(environmentFile.path)'
        for last; do :; done
        cd / && exec sh -c "$last"

        """.utf8
      ).write(to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
      runner = GitRunner(
        extraEnvironment: gitEnvironment.merging(["GIT_SSH_COMMAND": script.path, "GIT_SSH_VARIANT": "ssh"]) { $1 })
    }

    var usedGitsSSH: Bool { FileManager.default.fileExists(atPath: sshRan.path) }
    func repository(_ folder: URL, account: String? = nil) -> Repository {
      var runner = runner
      runner.credentialAccount = account
      return Repository(url: folder, runner: runner)
    }
  }

  enum Login {
    case works, refused, unreachable

    func connector(_ served: ServedRepository) -> GitSSH.Connector {
      switch self {
      case .works: return served.connector
      case .refused: return { _, _ in throw GitEngineError(.authentication, "The server didn't accept this key.") }
      case .unreachable: return { _, _ in throw GitEngineError(.network, "Couldn't reach the server.") }
      }
    }
  }

  /// Runs `body` as the app would at `level`, the connector logging in as `login` says.
  func at<T>(
    _ level: GitSecurityLevel, _ served: ServedRepository, login: Login = .works,
    ssh: SSHClientAddress? = nil, _ body: () async throws -> T
  ) async rethrows -> T {
    let configuration = GitNetwork.Configuration(
      engine: GitEngineNetwork(), level: { level }, sshClientAddress: { _ in ssh })
    return try await GitNetwork.$scoped.withValue(configuration) {
      try await GitSSH.$scoped.withValue(login.connector(served)) { try await body() }
    }
  }

  // MARK: The token

  /// Anything git runs sees its environment: a hook here. Only `useGit` puts the token there.
  @Test(arguments: GitSecurityLevel.allCases) func tokenReachesAProcessOnlyAtUseGit(level: GitSecurityLevel) async throws {
    guard level != .vaultKeyOnly else { return }
    let scene = try Scene()
    let account = UUID().uuidString
    GitCredentials.set(GitCredential(username: "octo", password: "very-secret-token"), for: "github.com", account: account)
    defer { GitCredentials.set(nil, for: "github.com", account: account) }
    let folder = try scene.served.clone()
    let hook = folder.appendingPathComponent(".git/hooks/pre-push")
    let seen = scene.served.fixture.sibling("hook-environment")
    try Data("#!/bin/sh\nenv > '\(seen.path)'\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    try commit("change.txt", "change\n", in: folder)
    try await at(level, scene.served) { try await scene.repository(folder, account: account).push() }
    let environment = try String(contentsOf: seen, encoding: .utf8)
    #expect(environment.contains("very-secret-token") == (level == .useGit))
    #expect(environment.contains("GITKIT_") == (level == .useGit))
    #expect(try scene.served.revision("main") == (try scene.served.revision("HEAD", in: folder)))
  }

  // MARK: In-app first

  @Test func inAppFirstDoesItInTheApp() async throws {
    let scene = try Scene()
    let folder = try scene.served.clone()
    let repository = scene.repository(folder)
    try commit("change.txt", "change\n", in: folder)
    try await at(.inAppFirst, scene.served) {
      try await repository.push()
      try await repository.fetch()
      try await repository.pull()
    }
    #expect(!scene.usedGitsSSH)
    #expect(scene.served.log.commands.count >= 3)
    #expect(try scene.served.revision("main") == (try scene.served.revision("HEAD", in: folder)))
  }

  @Test func inAppFirstFallsBackWhenTheKeyIsRefused() async throws {
    let scene = try Scene()
    let folder = try scene.served.clone()
    try commit("change.txt", "change\n", in: folder)
    try await at(.inAppFirst, scene.served, login: .refused) { try await scene.repository(folder).push() }
    #expect(scene.usedGitsSSH)
    #expect(try scene.served.revision("main") == (try scene.served.revision("HEAD", in: folder)))
  }

  /// A host says no with the command's words when the key signs in but has no access.
  @Test func aRepositoryTheKeyCantSeeFallsBack() async throws {
    let scene = try Scene()
    let folder = try scene.served.clone()
    let connector: GitSSH.Connector = { _, _ in
      try SSHRemoteTests.ProcessChannel(command: "echo 'ERROR: Repository not found.' >&2; exit 1")
    }
    let configuration = GitNetwork.Configuration(engine: GitEngineNetwork(), level: { .inAppFirst }, sshClientAddress: nil)
    try await GitNetwork.$scoped.withValue(configuration) {
      try await GitSSH.$scoped.withValue(connector) { try await scene.repository(folder).fetch() }
    }
    #expect(scene.usedGitsSSH)
  }

  @Test func aRejectedPushDoesntFallBack() async throws {
    let scene = try Scene()
    let folder = try scene.served.clone()
    try scene.served.commitUpstream("theirs.txt", "theirs\n")
    try commit("mine.txt", "mine\n", in: folder)
    await at(.inAppFirst, scene.served) {
      await #expect(throws: GitEngineError.self) { try await scene.repository(folder).push() }
    }
    #expect(!scene.usedGitsSSH)
  }

  @Test func aServerRefusalDoesntFallBack() async throws {
    let scene = try Scene()
    let folder = try scene.served.clone()
    let hook = scene.served.bare.appendingPathComponent("hooks/pre-receive")
    try Data("#!/bin/sh\necho no >&2\nexit 1\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    try commit("mine.txt", "mine\n", in: folder)
    await at(.inAppFirst, scene.served) {
      await #expect(throws: GitEngineError.self) { try await scene.repository(folder).push() }
    }
    #expect(!scene.usedGitsSSH)
  }

  @Test func aNetworkFailureDoesntFallBack() async throws {
    let scene = try Scene()
    let folder = try scene.served.clone()
    await at(.inAppFirst, scene.served, login: .unreachable) {
      await #expect(throws: GitEngineError.self) { try await scene.repository(folder).fetch() }
    }
    #expect(!scene.usedGitsSSH)
  }

  @Test func repositoriesTheEngineCantDoGoToGit() async throws {
    // Each of these keeps the app out; the fetch still has to work.
    for (name, arrange): (String, (URL) throws -> Void) in [
      ("shallow", { try Data().write(to: $0.appendingPathComponent(".git/shallow")) }),
      ("partial", { try git(["config", "remote.origin.promisor", "true"], in: $0) }),
      ("own ssh", { try git(["config", "core.fsmonitor", "false"], in: $0); try git(["config", "fetch.fsckObjects", "true"], in: $0) }),
    ] {
      let scene = try Scene()
      let folder = try scene.served.clone(name.replacingOccurrences(of: " ", with: "-"))
      try arrange(folder)
      // An empty shallow file means nothing to git.
      try await at(.inAppFirst, scene.served) { try await scene.repository(folder).fetch() }
      #expect(scene.usedGitsSSH, "\(name)")
    }
  }

  @Test func formatsTheEngineDoesntRead() throws {
    let fixture = try Fixture(initialize: false)
    let sha256 = fixture.sibling("sha256")
    try git(["init", "-q", "--object-format=sha256", sha256.path], in: fixture.parent)
    #expect(RepositoryChecks(context: try GitContext(worktree: sha256)).format?.contains("SHA-256") == true)
    let reftable = fixture.sibling("reftable")
    try git(["init", "-q", "--ref-format=reftable", reftable.path], in: fixture.parent)
    #expect(RepositoryChecks(context: try GitContext(worktree: reftable)).format?.contains("reftable") == true)
    let plain = fixture.sibling("plain")
    try git(["init", "-q", plain.path], in: fixture.parent)
    #expect(RepositoryChecks(context: try GitContext(worktree: plain)).format == nil)
    try git(["config", "extensions.partialClone", "origin"], in: plain)
    try git(["config", "core.repositoryformatversion", "1"], in: plain)
    #expect(RepositoryChecks(context: try GitContext(worktree: plain)).format?.contains("partial") == true)
  }

  @Test func hookAndLFSRepositoriesPushWithGit() async throws {
    // A hook runs, and can stop the push.
    let scene = try Scene()
    let folder = try scene.served.clone()
    let hook = folder.appendingPathComponent(".git/hooks/pre-push")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    try commit("mine.txt", "mine\n", in: folder)
    let before = try scene.served.revision("main")
    await at(.inAppFirst, scene.served) {
      await #expect(throws: GitError.self) { try await scene.repository(folder).push() }
    }
    #expect(try scene.served.revision("main") == before)
    #expect(scene.served.log.commands.isEmpty)

    // LFS filters.
    let lfs = try Scene()
    let other = try lfs.served.clone()
    try commit(".gitattributes", "*.bin filter=lfs diff=lfs merge=lfs -text\n", in: other)
    try await at(.sshOnly, lfs.served) { try await lfs.repository(other).push() }
    #expect(lfs.usedGitsSSH)
    #expect(lfs.served.log.commands.isEmpty)
    // A fetch has nothing to do with them.
    try await at(.inAppFirst, lfs.served) { try await lfs.repository(other).fetch() }
    #expect(lfs.served.log.commands.count == 1)
  }

  @Test func ownSSHSetupGoesToGit() async throws {
    let scene = try Scene()
    let folder = try scene.served.clone()
    let alias = SSHClientAddress(hostname: "real.example", port: nil, isProxied: false)
    try await at(.inAppFirst, scene.served, ssh: alias) { try await scene.repository(folder).fetch() }
    #expect(scene.usedGitsSSH)
    #expect(scene.served.log.commands.isEmpty)
    // The same setup with a login the app would use is left to the app.
    let same = try Scene()
    let second = try same.served.clone()
    let real = SSHClientAddress(hostname: "example.invalid", port: 22, isProxied: false)
    try await at(.inAppFirst, same.served, ssh: real) { try await same.repository(second).fetch() }
    #expect(!same.usedGitsSSH)
    // core.sshCommand.
    let third = try Scene()
    let folderThree = try third.served.clone()
    try git(["config", "core.sshCommand", third.runner.extraEnvironment["GIT_SSH_COMMAND"]!], in: folderThree)
    try await at(.inAppFirst, third.served) { try await third.repository(folderThree).fetch() }
    #expect(third.usedGitsSSH)
  }

  // MARK: Pull

  enum PullResult { case merged, rebased, fastForwarded, refused }

  @Test(arguments: [
    (["pull.rebase": "false"], PullResult.merged), (["pull.rebase": "true"], .rebased), (["pull.ff": "only"], .refused),
    ([:], .refused), (["pull.ff": "true"], .merged), (["branch.main.rebase": "true", "pull.rebase": "false"], .rebased),
  ]) func pullOnADivergedBranchFollowsTheSettings(settings: [String: String], result: PullResult) async throws {
    let scene = try Scene()
    let folder = try scene.served.clone()
    for (key, value) in settings { try git(["config", key, value], in: folder) }
    try scene.served.commitUpstream("theirs.txt", "theirs\n")
    try commit("mine.txt", "mine\n", in: folder)
    let mine = try scene.served.revision("HEAD", in: folder)
    do {
      try await at(.inAppFirst, scene.served) { try await scene.repository(folder).pull() }
      #expect(result != .refused)
    } catch {
      #expect(result == .refused, "\(error)")
      #expect(try scene.served.revision("HEAD", in: folder) == mine)
    }
    #expect(!scene.usedGitsSSH)
    let parents = try git(["log", "-1", "--format=%p"], in: folder).split(separator: " ").count
    let subject = try git(["log", "-1", "--format=%s"], in: folder)
    switch result {
    case .merged:
      #expect(parents == 2)
      #expect(subject == "Merge branch 'main' of ssh://example.invalid\(scene.served.bare.path.replacingOccurrences(of: ".git", with: ""))\n")
    case .rebased:
      #expect(parents == 1)
      #expect(subject == "Change mine.txt\n")
      #expect(try git(["merge-base", "--is-ancestor", "origin/main", "HEAD"], in: folder) == "")
    case .fastForwarded, .refused: break
    }
  }

  @Test func pullFastForwardsAndKeepsConflictsInProgress() async throws {
    let scene = try Scene()
    let folder = try scene.served.clone()
    try scene.served.commitUpstream("theirs.txt", "theirs\n")
    try await at(.inAppFirst, scene.served) { try await scene.repository(folder).pull() }
    #expect(try scene.served.revision("HEAD", in: folder) == (try scene.served.revision("main")))
    #expect(try git(["status", "--porcelain"], in: folder) == "")

    // Already up to date.
    try await at(.inAppFirst, scene.served) { try await scene.repository(folder).pull() }

    try git(["config", "pull.rebase", "false"], in: folder)
    try scene.served.commitUpstream("theirs.txt", "theirs two\n")
    try commit("theirs.txt", "mine two\n", in: folder)
    await at(.inAppFirst, scene.served) {
      await #expect(throws: GitError.self) { try await scene.repository(folder).pull() }
    }
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git/MERGE_HEAD").path))
  }

  // MARK: SSH only

  /// `https://example.invalid/…`: an HTTPS address whose SSH address reaches the served repository.
  func httpsAddress(_ served: ServedRepository) -> String { "https://example.invalid\(served.bare.path)" }

  @Test func sshOnlyMovesRemotesOnTheNextAction() async throws {
    let scene = try Scene()
    let https = httpsAddress(scene.served)
    let folder = try scene.served.clone(url: https)
    try git(["config", "remote.origin.pushurl", https], in: folder)
    try commit("mine.txt", "mine\n", in: folder)
    try await at(.sshOnly, scene.served) { try await scene.repository(folder).push() }
    let moved = "git@example.invalid:\(scene.served.bare.path.dropFirst())"
    #expect(try git(["config", "remote.origin.url"], in: folder) == moved + "\n")
    #expect(try git(["config", "remote.origin.pushurl"], in: folder) == moved + "\n")
    #expect(try scene.served.revision("main") == (try scene.served.revision("HEAD", in: folder)))

    // Back at a lower level, the next action puts the addresses back.
    await at(.inAppFirst, scene.served) {
      // It's HTTPS again, which this fake server isn't: the action itself can't succeed.
      _ = try? await scene.repository(folder).fetch()
    }
    #expect(try git(["config", "remote.origin.url"], in: folder) == https + "\n")
    #expect(try git(["config", "remote.origin.pushurl"], in: folder) == https + "\n")
    #expect(try git(["config", "--get-regexp", "v57"], in: folder, allowingFailure: true) == "")
  }

  @Test func sshOnlyChangesNothingWhenTheKeyDoesntWork() async throws {
    for login in [Login.refused, .unreachable] {
      let scene = try Scene()
      let https = httpsAddress(scene.served)
      let folder = try scene.served.clone(url: https)
      let config = try String(contentsOf: folder.appendingPathComponent(".git/config"), encoding: .utf8)
      await at(.sshOnly, scene.served, login: login) {
        await #expect(throws: GitEngineError.self) { try await scene.repository(folder).fetch() }
      }
      #expect(try String(contentsOf: folder.appendingPathComponent(".git/config"), encoding: .utf8) == config)
      #expect(!scene.usedGitsSSH)
    }
  }

  @Test func sshOnlyFallsBackOverSSHAndKeepsWhatItCan() async throws {
    let scene = try Scene()
    let folder = try scene.served.clone()
    try commit("mine.txt", "mine\n", in: folder)
    try await at(.sshOnly, scene.served, login: .refused) { try await scene.repository(folder).push() }
    #expect(scene.usedGitsSSH)
    #expect(try String(contentsOf: scene.environmentFile, encoding: .utf8).contains("GIT_ALLOW_PROTOCOL=ssh:file"))

    // One remote it can't move doesn't hold up the others, and is still reported.
    let second = try Scene()
    let other = try second.served.clone()
    try git(["remote", "add", "web", "git://example.invalid/repo.git"], in: other)
    try second.served.commitUpstream("new.txt", "new\n")
    await at(.sshOnly, second.served) {
      await #expect(throws: GitEngineError.self) { try await second.repository(other).fetch() }
    }
    #expect(try second.served.revision("origin/main", in: other) == (try second.served.revision("main")))
  }

  @Test func aRemoteChangedByHandStays() async throws {
    let scene = try Scene()
    let https = httpsAddress(scene.served)
    let folder = try scene.served.clone(url: https)
    try await at(.sshOnly, scene.served) { try await scene.repository(folder).fetch() }
    try git(["remote", "set-url", "origin", scene.served.url], in: folder)
    try await at(.inAppFirst, scene.served) { try await scene.repository(folder).fetch() }
    #expect(try git(["config", "remote.origin.url"], in: folder) == scene.served.url + "\n")
    #expect(try git(["config", "--get-regexp", "v57"], in: folder, allowingFailure: true) == "")
  }

  // MARK: Vault key only

  @Test func vaultKeyOnlyNeverRunsGitOnTheNetwork() async throws {
    let scene = try Scene()
    let folder = try scene.served.clone()
    try commit("mine.txt", "mine\n", in: folder)
    // A hook doesn't run here, as Settings says.
    let hook = folder.appendingPathComponent(".git/hooks/pre-push")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    try await at(.vaultKeyOnly, scene.served) {
      try await scene.repository(folder).push()
      try await scene.repository(folder).fetch()
      try await scene.repository(folder).pull()
    }
    #expect(!scene.usedGitsSSH)
    #expect(try scene.served.revision("main") == (try scene.served.revision("HEAD", in: folder)))
  }

  func refusal(_ level: GitSecurityLevel, _ scene: Scene, ssh: SSHClientAddress? = nil, _ action: () async throws -> Void) async -> String {
    do {
      try await at(level, scene.served, ssh: ssh) { try await action() }
      Issue.record("It wasn't refused")
      return ""
    } catch {
      #expect(!scene.usedGitsSSH)
      return error.localizedDescription
    }
  }

  @Test func vaultKeyOnlyRefusesAndSaysWhy() async throws {
    // HTTPS, untouched.
    var scene = try Scene()
    let https = httpsAddress(scene.served)
    var folder = try scene.served.clone(url: https)
    var message = await refusal(.vaultKeyOnly, scene) { try await scene.repository(folder).fetch() }
    #expect(message.contains("SSH"))
    #expect(try git(["config", "remote.origin.url"], in: folder) == https + "\n")

    // A folder.
    scene = try Scene()
    folder = try scene.served.clone(url: scene.served.bare.path)
    message = await refusal(.vaultKeyOnly, scene) { try await scene.repository(folder).fetch() }
    #expect(message.contains("folder"))

    // ~/.ssh/config.
    scene = try Scene()
    folder = try scene.served.clone()
    let alias = SSHClientAddress(hostname: "real.example", port: nil, isProxied: false)
    message = await refusal(.vaultKeyOnly, scene, ssh: alias) { try await scene.repository(folder).fetch() }
    #expect(message.contains(".ssh/config"))

    // Pushing LFS would leave pointers without their files.
    scene = try Scene()
    folder = try scene.served.clone()
    try commit(".gitattributes", "*.bin filter=lfs -text\n", in: folder)
    let before = try scene.served.revision("main")
    message = await refusal(.vaultKeyOnly, scene) { try await scene.repository(folder).push() }
    #expect(message.contains("LFS"))
    #expect(try scene.served.revision("main") == before)
    message = await refusal(.vaultKeyOnly, scene) { try await scene.repository(folder).pull() }
    #expect(message.contains("LFS"))

    // Submodules.
    scene = try Scene()
    folder = try scene.served.clone()
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git/modules/sub"), withIntermediateDirectories: true)
    message = await refusal(.vaultKeyOnly, scene) { try await scene.repository(folder).fetch() }
    #expect(message.contains("submodules"))

    // The key refused: nothing to fall back on.
    scene = try Scene()
    folder = try scene.served.clone()
    await at(.vaultKeyOnly, scene.served, login: .refused) {
      await #expect(throws: GitEngineError.self) { try await scene.repository(folder).fetch() }
    }
    #expect(!scene.usedGitsSSH)

    // A format it doesn't read.
    scene = try Scene()
    folder = try scene.served.clone()
    try Data().write(to: folder.appendingPathComponent(".git/shallow"))
    message = await refusal(.vaultKeyOnly, scene) { try await scene.repository(folder).fetch() }
    #expect(message.contains("shallow"))
  }

  // MARK: Clone

  @Test func clonesAtEachLevel() async throws {
    // In the app, then git's checkout.
    let scene = try Scene()
    let first = scene.served.fixture.sibling("first")
    let repository = try await at(.inAppFirst, scene.served) {
      try await Repository.clone(scene.served.url, to: first, runner: scene.runner)
    }
    #expect(!scene.usedGitsSSH)
    #expect(try git(["status", "--porcelain"], in: first) == "")
    #expect(try scene.served.revision("HEAD", in: first) == (try scene.served.revision("main")))
    #expect(try git(["config", "branch.main.remote"], in: first) == "origin\n")
    #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("README.md").path))
    #expect(repository.url.path == first.path)
    try git(["fsck", "--strict", "--no-dangling"], in: first)

    // Refused key: git, into the place the app left clean.
    let second = scene.served.fixture.sibling("second")
    _ = try await at(.inAppFirst, scene.served, login: .refused) {
      try await Repository.clone(scene.served.url, to: second, runner: scene.runner)
    }
    #expect(scene.usedGitsSSH)
    #expect(try git(["status", "--porcelain"], in: second) == "")

    // SSH only moves what's typed as HTTPS.
    let third = scene.served.fixture.sibling("third")
    _ = try await at(.sshOnly, scene.served) {
      try await Repository.clone(httpsAddress(scene.served), to: third, runner: scene.runner)
    }
    #expect(try git(["config", "remote.origin.url"], in: third).hasPrefix("git@example.invalid:"))

    // Vault key only: not HTTPS, not a folder.
    let fourth = scene.served.fixture.sibling("fourth")
    for address in [httpsAddress(scene.served), scene.served.bare.path] {
      await at(.vaultKeyOnly, scene.served) {
        await #expect(throws: GitEngineError.self) {
          try await Repository.clone(address, to: fourth, runner: scene.runner)
        }
      }
      #expect(!FileManager.default.fileExists(atPath: fourth.path))
    }
    _ = try await at(.vaultKeyOnly, scene.served) {
      try await Repository.clone(scene.served.url, to: fourth, runner: scene.runner)
    }
    #expect(try git(["status", "--porcelain"], in: fourth) == "")

    // An empty repository has nothing to check out.
    let empty = scene.served.fixture.sibling("empty.git")
    try git(["init", "-q", "--bare", "-b", "main", empty.path], in: scene.served.fixture.parent)
    let fifth = scene.served.fixture.sibling("fifth")
    _ = try await at(.inAppFirst, scene.served) {
      try await Repository.clone("ssh://git@example.invalid\(empty.path)", to: fifth, runner: scene.runner)
    }
    #expect(try git(["symbolic-ref", "HEAD"], in: fifth) == "refs/heads/main\n")
  }

  // MARK: iPhone and iPad

  /// No git: always the app, levels 1 and 2 alike. Level 3 moves, level 4 refuses HTTPS.
  @Test func onADeviceWithoutGit() async throws {
    let engine = GitEngineNetwork()
    let scene = try Scene()
    let folder = try scene.served.clone()
    try commit("mine.txt", "mine\n", in: folder)
    for level in [GitSecurityLevel.useGit, .inAppFirst, .sshOnly, .vaultKeyOnly] {
      let request = GitNetworkRequest(level: level)
      let outcome = try await GitSSH.$scoped.withValue(scene.served.connector) {
        try await engine.perform(.fetch, in: folder, request: request)
      }
      #expect(outcome == .done)
    }
    let pushed = try await GitSSH.$scoped.withValue(scene.served.connector) {
      try await engine.perform(.push(force: false), in: folder, request: GitNetworkRequest(level: .inAppFirst))
    }
    #expect(pushed == .done)
    let pulled = try await GitSSH.$scoped.withValue(scene.served.connector) {
      try await engine.perform(.pull, in: folder, request: GitNetworkRequest(level: .useGit))
    }
    #expect(pulled == .done)
    // No fallback, whatever the level.
    let refused = Login.refused.connector(scene.served)
    await GitSSH.$scoped.withValue(refused) {
      await #expect(throws: GitEngineError.self) {
        _ = try await engine.perform(.fetch, in: folder, request: GitNetworkRequest(level: .useGit))
      }
    }

    let https = httpsAddress(scene.served)
    let moving = try scene.served.clone("moving", url: https)
    await GitSSH.$scoped.withValue(scene.served.connector) {
      await #expect(throws: GitEngineError.self) {
        _ = try await engine.perform(.fetch, in: moving, request: GitNetworkRequest(level: .vaultKeyOnly))
      }
    }
    #expect(try git(["config", "remote.origin.url"], in: moving) == https + "\n")
    _ = try await GitSSH.$scoped.withValue(scene.served.connector) {
      try await engine.perform(.fetch, in: moving, request: GitNetworkRequest(level: .sshOnly))
    }
    #expect(try git(["config", "remote.origin.url"], in: moving).hasPrefix("git@example.invalid:"))
    let cloned = scene.served.fixture.sibling("cloned")
    _ = try await GitSSH.$scoped.withValue(scene.served.connector) {
      try await engine.clone(https, to: cloned, request: GitNetworkRequest(level: .sshOnly))
    }
    #expect(try git(["status", "--porcelain"], in: cloned) == "")
  }
}

/// `git` that may fail, for a config key that may be gone.
func git(_ arguments: [String], in directory: URL, environment: [String: String] = [:], allowingFailure: Bool) throws -> String {
  (try? git(arguments, in: directory, environment: environment)) ?? ""
}

/// Credentials over HTTP(S).
@Suite struct PlainHTTPTests {
  /// Serves `https://git.test:<port>/…` from the test server on that port, keeping the `Authorization` header it saw.
  final class ForwardHTTPS: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var seen: [String] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "git.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var forwarding: URLSessionDataTask?

    override func startLoading() {
      var forwarded = request
      if let authorization = request.value(forHTTPHeaderField: "Authorization") {
        Self.lock.withLock { Self.seen.append(authorization) }
      }
      if request.httpBody == nil, let stream = request.httpBodyStream {
        stream.open()
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable {
          let count = stream.read(&buffer, maxLength: buffer.count)
          if count <= 0 { break }
          body.append(buffer, count: count)
        }
        stream.close()
        forwarded.httpBody = body
      }
      var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
      components.scheme = "http"
      components.host = "127.0.0.1"
      forwarded.url = components.url
      forwarding = URLSession.shared.dataTask(with: forwarded) { [self] data, response, error in
        if let error {
          client?.urlProtocol(self, didFailWithError: error)
          return
        }
        let http = response as! HTTPURLResponse
        let answer = HTTPURLResponse(
          url: request.url!, statusCode: http.statusCode, httpVersion: nil,
          headerFields: http.allHeaderFields as? [String: String])!
        client?.urlProtocol(self, didReceive: answer, cacheStoragePolicy: .notAllowed)
        if let data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
      }
      forwarding?.resume()
    }

    override func stopLoading() { forwarding?.cancel() }
  }

  @Test func theTokenNeverGoesOverPlainHTTP() throws {
    let account = UUID().uuidString
    GitCredentials.set(GitCredential(username: "octo", password: "token"), for: "github.com", account: account)
    defer { GitCredentials.set(nil, for: "github.com", account: account) }
    GitCredentials.$activeAccount.withValue(account) {
      #expect(SmartHTTP.credential(for: URL(string: "http://github.com/owner/repo.git")!) == nil)
      #expect(SmartHTTP.credential(for: URL(string: "HTTP://github.com/owner/repo.git")!) == nil)
      #expect(SmartHTTP.credential(for: URL(string: "https://github.com/owner/repo.git")!)?.password == "token")
      #expect(SmartHTTP.credential(for: URL(string: "https://example.com/owner/repo.git")!) == nil)
    }
    #expect(SmartHTTP.credential(for: URL(string: "https://github.com/owner/repo.git")!) == nil)

    // A redirect keeps headers: one off HTTPS or to another host loses the token.
    func redirect(to url: String) -> String? {
      var request = URLRequest(url: URL(string: url)!)
      request.setValue("Basic x", forHTTPHeaderField: "Authorization")
      return SmartHTTP.redirected(request, from: URL(string: "https://github.com/a/b"))
        .value(forHTTPHeaderField: "Authorization")
    }
    #expect(redirect(to: "https://github.com/c/d") != nil)
    #expect(redirect(to: "http://github.com/c/d") == nil)
    #expect(redirect(to: "https://evil.example/c/d") == nil)
  }

  /// In the app with the account's token, against a server that wants it; over plain HTTP the same token stays home.
  @Test func anHTTPSRemoteUsesTheAccountsToken() async throws {
    let remote = try RemoteTests.Remote(name: "private-project")
    defer { remote.server.stop() }
    let account = UUID().uuidString
    remote.server.requiredAuthorization = "Basic " + Data("user:secret".utf8).base64EncodedString()
    SmartHTTP.testProtocols = [ForwardHTTPS.self]
    GitCredentials.set(GitCredential(username: "user", password: "secret"), for: "git.test", account: account)
    GitCredentials.set(GitCredential(username: "user", password: "secret"), for: "127.0.0.1", account: account)
    defer {
      GitCredentials.set(nil, for: "git.test", account: account)
      GitCredentials.set(nil, for: "127.0.0.1", account: account)
    }
    let destination = remote.fixture.sibling("https-clone")
    let address = "https://git.test:\(remote.server.port)/private-project.git"
    let repository = try await GitCredentials.$activeAccount.withValue(account) {
      try await LocalRepository.clone(from: address, to: destination)
    }
    #expect(try git(["status", "--porcelain"], in: destination) == "")
    #expect(ForwardHTTPS.lock.withLock { ForwardHTTPS.seen.contains(remote.server.requiredAuthorization!) })

    // The push goes the same way, whichever account asks.
    try commit("mine.txt", "mine\n", in: destination)
    try await GitCredentials.$activeAccount.withValue(account) { try await repository.push() }
    #expect(try git(["rev-parse", "main"], in: remote.bare) == (try git(["rev-parse", "HEAD"], in: destination)))
    await #expect(throws: GitEngineError.self) { try await repository.fetch() }

    do {
      _ = try await GitCredentials.$activeAccount.withValue(account) {
        try await LocalRepository.clone(from: remote.url, to: remote.fixture.sibling("plain"))
      }
      Issue.record("It sent the token over plain HTTP")
    } catch let error as GitEngineError {
      #expect(error.kind == .authentication)
    }
  }
}
