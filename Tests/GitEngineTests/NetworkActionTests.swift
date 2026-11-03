import Foundation
import GitKit
import Testing

@testable import GitEngine

/// A bare repository served "over SSH" (git's services through a shell, as `SSHRemoteTests`), a work repository that
/// fills it with real git, and a connector for it. Paths in addresses may be relative to `/`, as a moved HTTPS address is.
struct ServedRepository {
  /// What the connector was asked and how often it refused.
  final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var commandList: [String] = []
    func append(_ command: String) { lock.withLock { commandList.append(command) } }
    var commands: [String] { lock.withLock { commandList } }
  }

  let fixture: Fixture
  let bare: URL
  let log = Log()

  var url: String { "ssh://git@example.invalid\(bare.path)" }

  init(name: String = "served.git") throws {
    fixture = try Fixture(name: "work")
    try fixture.write("README.md", "# Project\n")
    try fixture.write("src/main.swift", Fixture.lines(1...100))
    try fixture.commitAll("Initial commit")
    try fixture.write("src/main.swift", Fixture.lines(1...101))
    try fixture.commitAll("Second")
    try fixture.git("tag", "-a", "v1", "-m", "One")
    bare = fixture.sibling(name)
    try git(["clone", "-q", "--bare", fixture.root.path, bare.path], in: fixture.root)
    try git(["config", "receive.denyCurrentBranch", "ignore"], in: bare)
    try fixture.git("remote", "add", "origin", bare.path)
    try fixture.git("fetch", "-q", "origin")
  }

  /// Runs what it's given on this machine.
  var connector: GitSSH.Connector {
    let log = log
    return { _, command in
      log.append(command)
      return try SSHRemoteTests.ProcessChannel(command: "cd / && exec " + command)
    }
  }

  /// A clone real git made, with `origin` at `url` (the served address by default) and its identity set.
  func clone(_ name: String = "clone", url: String? = nil) throws -> URL {
    let folder = fixture.sibling(name)
    try git(["clone", "-q", bare.path, folder.path], in: fixture.parent)
    try git(["remote", "set-url", "origin", url ?? self.url], in: folder)
    return folder
  }

  /// A commit in the work repository, pushed to the bare one with git.
  func commitUpstream(_ path: String, _ text: String, branch: String = "main") throws {
    try fixture.git("switch", "-q", branch)
    try fixture.write(path, text)
    try fixture.commitAll("Change \(path)")
    try fixture.git("push", "-q", "origin", branch)
  }

  func revision(_ name: String, in folder: URL? = nil) throws -> String {
    try git(["rev-parse", name], in: folder ?? bare).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// A commit with real git in `folder`.
func commit(_ path: String, _ text: String, in folder: URL) throws {
  try Data(text.utf8).write(to: folder.appendingPathComponent(path))
  try git(["add", "-A"], in: folder)
  try git(["commit", "-q", "-m", "Change \(path)"], in: folder)
}

/// The Mac's network actions in GitEngine, against what real git does.
@Suite struct NetworkActionTests {
  @Test func fetchesEveryRemoteWithPruneAndTags() async throws {
    let served = try ServedRepository()
    let other = try ServedRepository(name: "other.git")
    let folder = try served.clone()
    try git(["remote", "add", "fork", "ssh://git@example.invalid\(other.bare.path)"], in: folder)
    let twin = try served.clone("twin", url: served.bare.path)
    try git(["remote", "add", "fork", other.bare.path], in: twin)
    // Something for each: a new branch, a new tag, and a branch that goes away.
    try git(["branch", "doomed"], in: served.fixture.root)
    try served.fixture.git("push", "-q", "origin", "doomed")
    try git(["fetch", "-q", "--all"], in: twin)
    try await GitSSH.$scoped.withValue(served.connector) { try await LocalRepository(url: folder).fetch() }
    #expect(try git(["for-each-ref", "refs/remotes/origin/doomed"], in: folder) != "")
    try git(["push", "-q", served.bare.path, ":doomed"], in: served.fixture.root)
    try served.commitUpstream("new.txt", "new\n")
    try served.fixture.git("tag", "v2")
    try served.fixture.git("push", "-q", "origin", "v2")
    try git(["fetch", "-q", "--all", "--prune"], in: twin)
    try await GitSSH.$scoped.withValue(served.connector) { try await LocalRepository(url: folder).fetch() }
    let refs = "--format=%(objectname) %(refname)"
    let ours = try git(["for-each-ref", refs], in: folder)
    let theirs = try git(["for-each-ref", refs], in: twin)
    #expect(ours == theirs)
    try git(["fsck", "--strict", "--no-dangling"], in: folder)
  }

  @Test func fetchLeavesFetchHeadAsGitDoes() async throws {
    let served = try ServedRepository()
    let folder = try served.clone()
    let twin = try served.clone("twin", url: served.bare.path)
    try served.commitUpstream("new.txt", "new\n")
    try git(["fetch", "-q", "origin"], in: twin)
    try await GitSSH.$scoped.withValue(served.connector) { try await LocalRepository(url: folder).fetch() }
    func lines(_ folder: URL) throws -> [String] {
      try String(contentsOf: folder.appendingPathComponent(".git/FETCH_HEAD"), encoding: .utf8)
        .split(separator: "\n").map { $0.components(separatedBy: " of ")[0] }.sorted()
    }
    #expect(try lines(folder) == (try lines(twin)))
    // The first line is what a merge takes.
    #expect(try served.revision("FETCH_HEAD", in: folder) == (try served.revision("main")))
    #expect(Fetcher.anonymized("git@github.com:owner/repo.git") == "github.com:owner/repo")
    #expect(Fetcher.anonymized("https://user@github.com/owner/repo.git/") == "https://github.com/owner/repo")
  }

  /// A refspec beyond branches and tags: protocol v2 lists only what's asked for, and what isn't listed gets pruned.
  @Test func customRefspecsSurviveAFetchOverHTTP() async throws {
    let remote = try RemoteTests.Remote()
    defer { remote.server.stop() }
    let head = try git(["rev-parse", "main"], in: remote.bare).trimmingCharacters(in: .whitespacesAndNewlines)
    try git(["update-ref", "refs/pull/1/head", head], in: remote.bare)
    let destination = remote.fixture.sibling("custom")
    let repository = try await LocalRepository.clone(from: remote.url, to: destination)
    try git(["config", "--add", "remote.origin.fetch", "+refs/pull/*/head:refs/remotes/origin/pr/*"], in: destination)
    try await repository.fetch()
    try await repository.fetch()
    #expect(try git(["rev-parse", "refs/remotes/origin/pr/1"], in: destination).hasPrefix(head))
  }

  @Test func forcePushNeedsTheRemoteWhereItWasLastFetched() async throws {
    let served = try ServedRepository()
    let folder = try served.clone()
    try git(["reset", "-q", "--hard", "HEAD~1"], in: folder)
    try commit("mine.txt", "mine\n", in: folder)
    let repository = try LocalRepository(url: folder)
    try await GitSSH.$scoped.withValue(served.connector) {
      // Without force, a rewritten history is refused.
      await #expect(throws: GitEngineError.self) { try await repository.push() }
      try await repository.push(force: true)
    }
    #expect(try served.revision("main") == (try served.revision("HEAD", in: folder)))
    try git(["fsck", "--strict", "--no-dangling"], in: served.bare)

    // Someone else pushes: the lease no longer holds, as with git.
    try served.fixture.git("fetch", "-q", "origin")
    try served.fixture.git("reset", "-q", "--hard", "origin/main")
    try served.commitUpstream("theirs.txt", "theirs\n")
    try commit("second.txt", "second\n", in: folder)
    let before = try served.revision("main")
    await GitSSH.$scoped.withValue(served.connector) {
      await #expect(throws: GitEngineError.self) { try await repository.push(force: true) }
    }
    #expect(try served.revision("main") == before)
    #expect(throws: GitFailure.self) {
      try git(["push", "-q", "--force-with-lease", served.bare.path, "main:main"], in: folder)
    }
  }

  @Test func deletesARemoteBranchItHasSeen() async throws {
    let served = try ServedRepository()
    try git(["branch", "feature"], in: served.fixture.root)
    try served.fixture.git("push", "-q", "origin", "feature")
    let folder = try served.clone()
    let repository = try LocalRepository(url: folder)
    let tip = try served.revision("refs/remotes/origin/feature", in: folder)

    // It moved since: stays, and the message says to look.
    try served.commitUpstream("feature.txt", "more\n", branch: "feature")
    await GitSSH.$scoped.withValue(served.connector) {
      await #expect(throws: GitEngineError.self) {
        try await repository.deleteRemoteBranch("feature", on: "origin", expected: tip)
      }
    }
    #expect(try git(["for-each-ref", "refs/heads/feature"], in: served.bare) != "")

    try await GitSSH.$scoped.withValue(served.connector) {
      try await repository.fetch()
      let fresh = try served.revision("refs/remotes/origin/feature", in: folder)
      try await repository.deleteRemoteBranch("feature", on: "origin", expected: fresh)
    }
    #expect(try git(["for-each-ref", "refs/heads/feature"], in: served.bare) == "")
    #expect(try git(["for-each-ref", "refs/remotes/origin/feature"], in: folder) == "")
  }

  @Test func pushesWhereGitWould() async throws {
    let served = try ServedRepository()
    let fork = try ServedRepository(name: "fork.git")
    let folder = try served.clone()
    try git(["remote", "add", "fork", "ssh://git@example.invalid\(fork.bare.path)"], in: folder)
    try git(["switch", "-q", "-c", "feature"], in: folder)
    try commit("feature.txt", "feature\n", in: folder)
    let repository = try LocalRepository(url: folder)
    let context = try GitContext(worktree: folder)
    #expect(try context.pushRemote(for: "feature") == "origin")
    try git(["config", "remote.pushDefault", "fork"], in: folder)
    #expect(try GitContext(worktree: folder).pushRemote(for: "feature") == "fork")
    try await GitSSH.$scoped.withValue(served.connector) { try await repository.push() }
    #expect(try served.revision("refs/heads/feature", in: fork.bare) == (try served.revision("feature", in: folder)))
    #expect(try git(["for-each-ref", "refs/heads/feature"], in: served.bare) == "")
    #expect(try git(["config", "branch.feature.remote"], in: folder) == "fork\n")
    try git(["config", "branch.feature.pushRemote", "origin"], in: folder)
    #expect(try GitContext(worktree: folder).pushRemote(for: "feature") == "origin")

    // Several remotes and no default: the same words as `Repository.pushRemote`.
    try git(["config", "--unset", "remote.pushDefault"], in: folder)
    try git(["config", "--unset", "branch.feature.pushRemote"], in: folder)
    try git(["config", "--unset", "branch.feature.remote"], in: folder)
    try git(["config", "--unset", "branch.feature.merge"], in: folder)
    try git(["remote", "rename", "origin", "upstream"], in: folder)
    #expect(throws: GitEngineError.self) { try GitContext(worktree: folder).pushRemote(for: "feature") }
  }

  @Test func pushesToEveryPushAddressAndFollowsInsteadOf() async throws {
    let served = try ServedRepository()
    let mirror = served.fixture.sibling("mirror.git")
    try git(["clone", "-q", "--bare", served.bare.path, mirror.path], in: served.fixture.parent)
    let folder = try served.clone()
    try git(["config", "--add", "remote.origin.pushurl", "ssh://git@example.invalid\(served.bare.path)"], in: folder)
    try git(["config", "--add", "remote.origin.pushurl", "mine:\(mirror.path)"], in: folder)
    try git(["config", "url.ssh://git@example.invalid.insteadOf", "mine:"], in: folder)
    try commit("both.txt", "both\n", in: folder)
    try await GitSSH.$scoped.withValue(served.connector) { try await LocalRepository(url: folder).push() }
    let head = try served.revision("HEAD", in: folder)
    #expect(try served.revision("main") == head)
    #expect(try served.revision("main", in: mirror) == head)

    // Settings from outside `.git/config` count where git's there to ask.
    let settings = [
      GitSetting(key: "remote.a.url", value: "gh:owner/repo"), GitSetting(key: "remote.a.pushurl", value: "gh:push/repo"),
      GitSetting(key: "url.https://github.com/.insteadof", value: "gh:"),
      GitSetting(key: "url.git@github.com:.pushinsteadof", value: "other:"),
      GitSetting(key: "remote.b.url", value: "other:owner/repo"),
    ]
    let context = try GitContext(worktree: folder, settings: settings)
    #expect(try context.fetchURL("a") == "https://github.com/owner/repo")
    #expect(try context.pushURLs("a") == ["https://github.com/push/repo"])
    #expect(try context.pushURLs("b") == ["git@github.com:owner/repo"])
  }

  /// A linked worktree shares objects, refs and config with its repository; a `.git` file says where.
  @Test func worksInALinkedWorktree() async throws {
    let served = try ServedRepository()
    let folder = try served.clone()
    let worktree = served.fixture.sibling("linked")
    try git(["worktree", "add", "-q", "-b", "side", worktree.path], in: folder)
    try commit("side.txt", "side\n", in: worktree)
    let repository = try LocalRepository(url: worktree)
    try served.commitUpstream("new.txt", "new\n")
    try await GitSSH.$scoped.withValue(served.connector) {
      try await repository.fetch()
      try await repository.push()
    }
    #expect(try served.revision("refs/heads/side") == (try served.revision("HEAD", in: worktree)))
    #expect(try served.revision("origin/main", in: folder) == (try served.revision("main")))
    #expect(try git(["config", "branch.side.remote"], in: folder) == "origin\n")
    // HEAD and the fetch's record stay the worktree's.
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git/worktrees/linked/FETCH_HEAD").path))
    #expect(try git(["symbolic-ref", "HEAD"], in: folder) == "refs/heads/main\n")
    try git(["fsck", "--strict", "--no-dangling"], in: folder)
  }

  @Test func namesFromAServerAreChecked() {
    #expect(RefName.isValid("refs/heads/main"))
    #expect(RefName.isValid("refs/pull/1/head"))
    #expect(RefName.isValid("HEAD"))
    #expect(!RefName.isValid("refs/heads/../../config"))
    #expect(!RefName.isValid("refs/heads/a\tb"))
    #expect(!RefName.isValid("config"))
    #expect(GitSSHAddress("ext::sh -c touch%20x") == nil)
    #expect(GitSSHAddress("git@[::1]:repo.git")?.host == "::1")
  }

  @Test func sshAddressOfAnHTTPSOne() {
    #expect(SSHRemote(httpsURL: "https://github.com/owner/repo.git")?.url == "git@github.com:owner/repo.git")
    #expect(SSHRemote(httpsURL: "https://me:token@GitHub.com:8443/owner/repo/")?.url == "git@GitHub.com:owner/repo")
    #expect(SSHRemote(httpsURL: "https://github.com/") == nil)
    #expect(SSHRemote(httpsURL: "git@github.com:owner/repo.git") == nil)
  }
}
