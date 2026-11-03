import Foundation
import GitKit
import Testing

@testable import GitEngine

/// Clone, fetch and push through `GitSSH`, with git's own services standing in for an SSH server's: the command goes
/// through a shell as sshd runs it, and its input and output are the channel's. The login itself is the app's.
@Suite(.serialized) struct SSHRemoteTests {
  /// A command on this machine as a channel.
  final class ProcessChannel: GitSSHChannel, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()
    private let writes = DispatchQueue(label: "writes")
    private let ended = DispatchSemaphore(value: 0)

    init(command: String) throws {
      signal(SIGPIPE, SIG_IGN)
      process.terminationHandler = { [ended] _ in ended.signal() }
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", command]
      process.standardInput = input
      process.standardOutput = output
      process.standardError = error
      try process.run()
    }

    func read() async throws -> Data? {
      await withCheckedContinuation { continuation in
        DispatchQueue.global().async { [output] in
          let data = output.fileHandleForReading.availableData
          continuation.resume(returning: data.isEmpty ? nil : data)
        }
      }
    }

    func write(_ data: Data) {
      writes.async { [input] in try? input.fileHandleForWriting.write(contentsOf: data) }
    }

    func finishWriting() {
      writes.async { [input] in try? input.fileHandleForWriting.close() }
    }

    func finished() async throws -> (errorOutput: String, status: Int32?) {
      await withCheckedContinuation { continuation in
        DispatchQueue.global().async { [process, error, ended] in
          let text = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
          // Once for each caller: it stays signalled.
          ended.wait()
          ended.signal()
          continuation.resume(returning: (text, process.terminationStatus))
        }
      }
    }

    func close() {
      if process.isRunning { process.terminate() }
    }
  }

  /// Commands the connector was asked to run.
  final class Commands: @unchecked Sendable {
    private var commands: [String] = []
    private let lock = NSLock()
    func append(_ command: String) { lock.withLock { commands.append(command) } }
    var all: [String] { lock.withLock { commands } }
  }

  /// A bare repository with some history, and a connector that runs what it's given on this machine.
  struct Remote {
    let fixture: Fixture
    let bare: URL
    let commands = Commands()

    /// The address the tests use: host and login don't matter here.
    var url: String { "ssh://git@example.invalid\(bare.path)" }

    init() throws {
      fixture = try Fixture(name: "work")
      try fixture.write("README.md", "# Project\n")
      try fixture.write("src/main.swift", Fixture.lines(1...100))
      try fixture.commitAll("Initial commit")
      try fixture.write("src/main.swift", Fixture.lines(1...101))
      try fixture.commitAll("Second")
      try fixture.git("tag", "-a", "v1", "-m", "One")
      bare = fixture.sibling("served.git")
      try git(["clone", "-q", "--bare", fixture.root.path, bare.path], in: fixture.root)
      try git(["config", "receive.denyCurrentBranch", "ignore"], in: bare)
      try fixture.git("remote", "add", "origin", bare.path)
      try fixture.git("fetch", "-q", "origin")
      let commands = commands
      GitSSH.setConnector { address, command in
        #expect(address.host == "example.invalid")
        commands.append(command)
        return try ProcessChannel(command: "exec " + command)
      }
    }
  }

  @Test func clonesLikeGit() async throws {
    let remote = try Remote()
    let destination = remote.fixture.sibling("clone")
    let repository = try await LocalRepository.clone(from: remote.url, to: destination)
    try git(["fsck", "--strict", "--no-dangling"], in: destination)
    #expect(try git(["status", "--porcelain"], in: destination) == "")
    #expect(try git(["rev-parse", "HEAD"], in: destination) == (try remote.fixture.git("rev-parse", "main")))
    #expect(try git(["tag"], in: destination) == "v1\n")
    let status = try await repository.status()
    #expect(status.isClean && status.upstream == "origin/main")
    #expect(remote.commands.all.allSatisfy { $0 == "git-upload-pack '\(remote.bare.path)'" })
  }

  @Test func clonesAnEmptyRepository() async throws {
    let remote = try Remote()
    let empty = remote.fixture.sibling("empty.git")
    try git(["init", "-q", "--bare", "-b", "main", empty.path], in: remote.fixture.root)
    let destination = remote.fixture.sibling("clone")
    _ = try await LocalRepository.clone(from: "ssh://git@example.invalid\(empty.path)", to: destination)
    #expect(try git(["status", "--porcelain"], in: destination) == "")
  }

  @Test func fetchesAndPullsWhatsNew() async throws {
    let remote = try Remote()
    let destination = remote.fixture.sibling("clone")
    let repository = try await LocalRepository.clone(from: remote.url, to: destination)
    try remote.fixture.write("src/main.swift", Fixture.lines(1...120))
    try remote.fixture.commitAll("Third")
    try remote.fixture.git("push", "-q", "origin", "main")
    try await repository.pull()
    #expect(try git(["rev-parse", "HEAD"], in: destination) == (try remote.fixture.git("rev-parse", "main")))
    try git(["fsck", "--strict", "--no-dangling"], in: destination)
    // Nothing new: the service is asked for nothing and ends quietly.
    try await repository.fetch()
    try await repository.pull()
  }

  @Test func pushesANewCommitAndANewBranch() async throws {
    let remote = try Remote()
    let destination = remote.fixture.sibling("clone")
    let repository = try await LocalRepository.clone(from: remote.url, to: destination)
    try Data("new\n".utf8).write(to: destination.appendingPathComponent("new.txt"))
    try git(["add", "new.txt"], in: destination)
    try git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "New"], in: destination)
    try await repository.push()
    let head = try git(["rev-parse", "HEAD"], in: destination)
    #expect(try git(["rev-parse", "main"], in: remote.bare) == head)
    try git(["fsck", "--strict", "--no-dangling"], in: remote.bare)
    #expect(remote.commands.all.last == "git-receive-pack '\(remote.bare.path)'")

    // Up to date: says so without sending anything.
    try await repository.push()

    try await repository.createBranch("feature")
    try await repository.switchTo(try await repository.branches().first { $0.name == "feature" }!)
    try Data("more\n".utf8).write(to: destination.appendingPathComponent("more.txt"))
    try git(["add", "more.txt"], in: destination)
    try git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "More"], in: destination)
    try await repository.push()
    #expect(try git(["rev-parse", "feature"], in: remote.bare) == (try git(["rev-parse", "HEAD"], in: destination)))
    #expect(try git(["config", "branch.feature.merge"], in: destination) == "refs/heads/feature\n")
  }

  @Test func refusesAPushThatWouldLoseTheRemotesCommits() async throws {
    let remote = try Remote()
    let destination = remote.fixture.sibling("clone")
    let repository = try await LocalRepository.clone(from: remote.url, to: destination)
    try remote.fixture.write("theirs.txt", "theirs\n")
    try remote.fixture.commitAll("Theirs")
    try remote.fixture.git("push", "-q", "origin", "main")
    try Data("ours\n".utf8).write(to: destination.appendingPathComponent("ours.txt"))
    try git(["add", "ours.txt"], in: destination)
    try git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "Ours"], in: destination)
    await #expect(throws: GitEngineError.self) { try await repository.push() }
  }

  @Test func saysWhatTheServerSaidWhenTheCommandFails() async throws {
    let remote = try Remote()
    GitSSH.setConnector { _, _ in
      try ProcessChannel(command: "echo 'ERROR: Repository not found.' >&2; exit 1")
    }
    let destination = remote.fixture.sibling("clone")
    await #expect {
      _ = try await LocalRepository.clone(from: remote.url, to: destination)
    } throws: { error in
      (error as? GitEngineError)?.message == "example.invalid: ERROR: Repository not found."
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func withoutAConnectorSSHRemotesAreRefused() async throws {
    GitSSH.setConnector(nil)
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("no-\(UUID().uuidString)")
    await #expect(throws: GitEngineError.self) {
      _ = try await LocalRepository.clone(from: "git@example.invalid:owner/repo.git", to: destination)
    }
  }

  @Test func readsAddresses() throws {
    let scp = try #require(GitSSHAddress("git@github.com:owner/repo.git"))
    #expect(scp.user == "git" && scp.host == "github.com" && scp.port == nil && scp.path == "owner/repo.git")
    let url = try #require(GitSSHAddress("ssh://git@github.com:2222/owner/repo.git"))
    #expect(url.user == "git" && url.host == "github.com" && url.port == 2222 && url.path == "/owner/repo.git")
    let home = try #require(GitSSHAddress("ssh://me@box/~/repo.git"))
    #expect(home.path == "~/repo.git" && home.port == nil)
    let noUser = try #require(GitSSHAddress("box:repo.git"))
    #expect(noUser.user == nil && noUser.host == "box")
    let ipv6 = try #require(GitSSHAddress("git@[::1]:repo.git"))
    #expect(ipv6.host == "::1" && ipv6.path == "repo.git")
    let ipv6URL = try #require(GitSSHAddress("ssh://git@[::1]:2222/repo.git"))
    #expect(ipv6URL.host == "::1" && ipv6URL.port == 2222)
    #expect(GitSSHAddress("git+ssh://git@github.com/owner/repo")?.path == "/owner/repo")

    for other in ["https://github.com/owner/repo", "/local/path.git", "./a:b", "file:///tmp/a", "-oProxyCommand=x:repo", "ssh://host"] {
      #expect(GitSSHAddress(other) == nil, "\(other)")
    }
    #expect(GitSSHAddress("git@github.com:o'wner/repo")?.command("git-upload-pack") == "git-upload-pack 'o'\\''wner/repo'")
  }
}
