import Foundation
import GitKit
import Testing

@testable import GitEngine

/// Clone, fetch, pull and push over HTTP against `git http-backend`.
@Suite struct RemoteTests {
  /// A bare repository `name.git` served over HTTP, filled from a work repository made by git.
  struct Remote {
    let fixture: Fixture
    let server: GitHTTPServer
    let bare: URL
    let url: String

    init(name: String = "project", version2: Bool = true) throws {
      fixture = try Fixture(name: "work")
      try fixture.write("README.md", "# Project\n")
      try fixture.write("src/main.swift", Fixture.lines(1...100))
      try fixture.write("bin/run.sh", "#!/bin/sh\n")
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: fixture.root.appendingPathComponent("bin/run.sh").path)
      try FileManager.default.createSymbolicLink(
        atPath: fixture.root.appendingPathComponent("link").path, withDestinationPath: "README.md")
      try fixture.commitAll("Initial commit")
      for round in 1...4 {
        try fixture.write("src/main.swift", Fixture.lines(1...(100 + round)))
        try fixture.commitAll("Round \(round)")
      }
      try fixture.git("tag", "-a", "v1", "-m", "One")
      try fixture.git("branch", "other", "HEAD~2")
      let served = fixture.sibling("served")
      try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
      bare = served.appendingPathComponent("\(name).git")
      try git(["clone", "-q", "--bare", fixture.root.path, bare.path], in: served)
      // Packed with deltas, as a real server's would be.
      try git(["repack", "-adq", "--depth=10"], in: bare)
      server = try GitHTTPServer(root: served)
      server.allowsVersion2 = version2
      url = "\(server.baseURL)/\(name).git"
      try fixture.git("remote", "add", "origin", bare.path)
      try fixture.git("fetch", "-q", "origin")
    }

    /// Commits in the work repository and pushes them to the bare one with git.
    func pushFromGit(_ path: String, _ text: String, branch: String = "main") throws {
      try fixture.git("switch", "-q", branch)
      try fixture.write(path, text)
      try fixture.commitAll("Change \(path)")
      try fixture.git("push", "-q", "origin", branch)
    }
  }

  func clone(_ remote: Remote, as name: String = "clone") async throws -> (LocalRepository, URL) {
    let destination = remote.fixture.sibling(name)
    let lines = Lines()
    let repository = try await LocalRepository.clone(from: remote.url, to: destination) { lines.append($0) }
    #expect(lines.all.contains { $0.hasPrefix("Receiving objects: 100%") })
    return (repository, destination)
  }

  /// Collects progress lines from any task.
  final class Lines: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
  }

  @Test(arguments: [true, false]) func clonesLikeGit(version2: Bool) async throws {
    let remote = try Remote(version2: version2)
    defer { remote.server.stop() }
    #expect(try await UploadPack.connect(remote.url).advertisement.version2 == version2)
    let (repository, destination) = try await clone(remote)
    try git(["fsck", "--strict", "--no-dangling"], in: destination)
    #expect(try git(["status", "--porcelain"], in: destination) == "")
    #expect(try git(["rev-parse", "HEAD"], in: destination) == (try remote.fixture.git("rev-parse", "main")))
    #expect(try git(["config", "branch.main.merge"], in: destination) == "refs/heads/main\n")
    #expect(try git(["config", "remote.origin.url"], in: destination) == remote.url + "\n")
    #expect(try git(["symbolic-ref", "refs/remotes/origin/HEAD"], in: destination) == "refs/remotes/origin/main\n")
    #expect(try git(["tag"], in: destination) == "v1\n")
    let main = try Data(contentsOf: destination.appendingPathComponent("src/main.swift"))
    #expect(main == Data(Fixture.lines(1...104).utf8))
    let link = try FileManager.default.destinationOfSymbolicLink(
      atPath: destination.appendingPathComponent("link").path)
    #expect(link == "README.md")
    let mode = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("bin/run.sh").path)
    #expect((mode[.posixPermissions] as? Int ?? 0) & 0o100 != 0)
    let status = try await repository.status()
    #expect(status.isClean && status.branch == "main" && status.upstream == "origin/main")
    #expect(try await repository.branches().map(\.name) == ["main", "origin/main", "origin/other"])
    // git can work in the clone.
    try git(["log", "--oneline", "-3"], in: destination)
    try git(["verify-pack", "-v"] + (try FileManager.default.contentsOfDirectory(
      atPath: destination.appendingPathComponent(".git/objects/pack").path).filter { $0.hasSuffix(".idx") }
      .map { ".git/objects/pack/" + $0 }), in: destination)
  }

  @Test func clonesWithoutDotGitAndFollowsRedirects() async throws {
    let remote = try Remote()
    defer { remote.server.stop() }
    let destination = remote.fixture.sibling("bare-name")
    _ = try await LocalRepository.clone(from: "\(remote.server.baseURL)/project", to: destination)
    #expect(try git(["status", "--porcelain"], in: destination) == "")
    let moved = remote.fixture.sibling("moved")
    _ = try await LocalRepository.clone(from: "\(remote.server.baseURL)/moved/project.git", to: moved)
    #expect(try git(["rev-parse", "HEAD"], in: moved) == (try remote.fixture.git("rev-parse", "main")))
  }

  @Test func fetchesAndFastForwards() async throws {
    let remote = try Remote()
    defer { remote.server.stop() }
    let (repository, destination) = try await clone(remote)
    try remote.pushFromGit("src/main.swift", Fixture.lines(1...120))
    try remote.pushFromGit("new-file.txt", "new\n")
    try remote.fixture.git("push", "-q", "origin", "--delete", "other")
    try remote.fixture.git("branch", "-q", "fresh", "main~1")
    try remote.fixture.git("push", "-q", "origin", "fresh")

    try await repository.fetch()
    var status = try await repository.status()
    #expect(status.behind == 2 && status.ahead == 0)
    #expect(try await repository.branches().map(\.name) == ["main", "origin/fresh", "origin/main"])
    try git(["fsck", "--strict"], in: destination)

    try fixtureWrite(destination, "README.md", "# Local edit\n")
    try await repository.pull()
    status = try await repository.status()
    #expect(status.behind == 0 && status.unstaged.map(\.path) == ["README.md"])
    #expect(try git(["rev-parse", "HEAD"], in: destination) == (try remote.fixture.git("rev-parse", "main")))
    #expect(try String(contentsOf: destination.appendingPathComponent("new-file.txt"), encoding: .utf8) == "new\n")
    #expect(try git(["status", "--porcelain"], in: destination) == " M README.md\n")
    try git(["fsck", "--strict"], in: destination)
    // Nothing new: a no-op.
    try await repository.pull()
  }

  @Test func pushesNewCommits() async throws {
    let remote = try Remote()
    defer { remote.server.stop() }
    let (repository, destination) = try await clone(remote)
    try fixtureWrite(destination, "src/main.swift", Fixture.lines(1...130))
    try fixtureWrite(destination, "docs/guide.md", "Guide\n")
    try await repository.stageAll()
    let sha = try await repository.commit(message: "Pushed by the engine", author: Fixture.author)
    #expect(try await repository.status().ahead == 1)
    let lines = Lines()
    try await repository.push { lines.append($0) }
    #expect(lines.all.contains { $0.hasPrefix("Writing objects: 100%") })
    #expect(try git(["rev-parse", "main"], in: remote.bare) == sha + "\n")
    try git(["fsck", "--strict"], in: remote.bare)
    let status = try await repository.status()
    #expect(status.ahead == 0 && status.behind == 0)
    #expect(try git(["rev-parse", "refs/remotes/origin/main"], in: destination) == sha + "\n")

    // A new branch is pushed under its own name and starts tracking it.
    try await repository.createBranch("topic")
    try fixtureWrite(destination, "topic.txt", "topic\n")
    try await repository.stageAll()
    let topic = try await repository.commit(message: "Topic", author: Fixture.author)
    try await repository.push()
    #expect(try git(["rev-parse", "topic"], in: remote.bare) == topic + "\n")
    #expect(try git(["config", "branch.topic.merge"], in: destination) == "refs/heads/topic\n")
    #expect(try await repository.status().upstream == "origin/topic")
    try git(["fsck", "--strict"], in: remote.bare)
  }

  @Test func pushesToAnEmptyRemote() async throws {
    let fixture = try Fixture(initialize: false)
    let served = fixture.sibling("served")
    try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
    try git(["init", "-q", "--bare", "-b", "main", served.appendingPathComponent("empty.git").path], in: served)
    let server = try GitHTTPServer(root: served)
    defer { server.stop() }
    let clone = try await LocalRepository.clone(from: "\(server.baseURL)/empty.git", to: fixture.root)
    #expect(try await clone.log().isEmpty)
    try fixture.write("first.txt", "first\n")
    try await clone.stageAll()
    let sha = try await clone.commit(message: "First", author: Fixture.author)
    try await clone.push()
    #expect(try git(["rev-parse", "main"], in: served.appendingPathComponent("empty.git")) == sha + "\n")
    try git(["fsck", "--strict"], in: served.appendingPathComponent("empty.git"))
  }

  @Test func refusesDivergedPullAndRejectedPush() async throws {
    let remote = try Remote()
    defer { remote.server.stop() }
    let (repository, destination) = try await clone(remote)
    try remote.pushFromGit("theirs.txt", "theirs\n")
    try fixtureWrite(destination, "mine.txt", "mine\n")
    try await repository.stageAll()
    _ = try await repository.commit(message: "Mine", author: Fixture.author)
    await #expect(throws: GitEngineError.self) { try await repository.push() }
    await #expect(throws: GitEngineError.self) { try await repository.pull() }
    let status = try await repository.status()
    #expect(status.ahead == 1 && status.behind == 1)
    #expect(try git(["status", "--porcelain"], in: destination) == "")
  }

  @Test func asksForCredentialsAndSendsThem() async throws {
    let remote = try Remote(name: "private-project")
    defer { remote.server.stop() }
    remote.server.requiredAuthorization = "Basic " + Data("user:secret".utf8).base64EncodedString()
    let destination = remote.fixture.sibling("private-clone")
    do {
      _ = try await LocalRepository.clone(from: remote.url, to: destination)
      Issue.record("Cloned without credentials")
    } catch let error as GitEngineError {
      #expect(error.kind == .authentication)
      #expect(error.message.contains("sign in"))
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    GitCredentials.set(GitCredential(username: "user", password: "secret"), for: "127.0.0.1")
    defer { GitCredentials.set(nil, for: "127.0.0.1") }
    _ = try await LocalRepository.clone(from: remote.url, to: destination)
    #expect(try git(["status", "--porcelain"], in: destination) == "")
  }

  @Test func reportsMissingRepositories() async throws {
    let remote = try Remote()
    defer { remote.server.stop() }
    do {
      _ = try await LocalRepository.clone(from: "\(remote.server.baseURL)/nothing.git", to: remote.fixture.sibling("x"))
      Issue.record("Cloned a missing repository")
    } catch let error as GitEngineError {
      #expect(error.kind == .notFound)
    }
    await #expect(throws: GitEngineError.self) {
      _ = try await LocalRepository.clone(from: "git@github.com:a/b.git", to: remote.fixture.sibling("y"))
    }
  }

  /// Opt-in: `GITENGINE_NETWORK_TESTS=1 swift test --filter GitEngineTests` clones a small public GitHub repository.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["GITENGINE_NETWORK_TESTS"] != nil))
  func clonesFromGitHub() async throws {
    let fixture = try Fixture(initialize: false)
    let repository = try await LocalRepository.clone(from: "https://github.com/octocat/Hello-World", to: fixture.root)
    try fixture.git("fsck", "--strict")
    #expect(try porcelain(fixture).isEmpty)
    #expect(try await repository.log().isEmpty == false)
    try await repository.fetch()
  }

  /// Opt-in: `GITENGINE_CLONE_URL=https://… swift test --filter clonesAnyRepository` clones a repository of your
  /// choice and compares the result with git.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["GITENGINE_CLONE_URL"] != nil))
  func clonesAnyRepository() async throws {
    let url = ProcessInfo.processInfo.environment["GITENGINE_CLONE_URL"]!
    let fixture = try Fixture(initialize: false)
    let start = Date()
    let repository = try await LocalRepository.clone(from: url, to: fixture.root)
    let cloned = Date()
    try fixture.git("fsck", "--strict", "--no-dangling")
    #expect(try porcelain(fixture).isEmpty)
    let statusStart = Date()
    let status = try await repository.status()
    let statusTime = Date().timeIntervalSince(statusStart)
    #expect(normalized(status) == normalized(try await fixture.gitKit.status()))
    #expect(try await repository.log().map(\.id) == (try await fixture.gitKit.log()).map(\.id))
    print("Cloned in \(cloned.timeIntervalSince(start)) s, status in \(statusTime) s")
  }

  private func fixtureWrite(_ root: URL, _ path: String, _ text: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }
}
