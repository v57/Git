import Foundation
import Testing

@testable import GitKit

/// A transport that runs this machine's git and counts what goes through it, standing in for git on another
/// machine (the iOS app's SSH transport).
final class RecordingTransport: GitTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [String] = []
  private var ranCommands: [String] = []
  private var lastNetworkEnvironment: [String: String] = [:]
  let runner = TempRepo.runner
  let machineID: String

  init(machineID: String = "") {
    self.machineID = machineID
  }

  var recorded: [String] { lock.withLock { calls } }
  /// The git commands that ran: `fetch`, `status`…
  var commands: [String] { lock.withLock { ranCommands } }
  /// The environment of the last call that had one.
  var environment: [String: String] { lock.withLock { lastNetworkEnvironment } }

  private func record(_ call: String) { lock.withLock { calls.append(call) } }

  func run(
    _ arguments: [String], in directory: URL?, input: Data?, environment: [String: String],
    progress: (@Sendable (String) -> Void)?
  ) async throws -> GitResult {
    record("git")
    lock.withLock { ranCommands.append(arguments.first { !$0.hasPrefix("-") && !$0.contains("=") } ?? "") }
    if !environment.isEmpty { lock.withLock { lastNetworkEnvironment = environment } }
    // The runner adds the global config again; git takes the repeated -c options.
    return try await runner.run(
      arguments, in: directory, input: input, allowedExitCodes: Set(0...255), environment: environment,
      progress: progress)
  }

  func contents(of url: URL) async throws -> Data? {
    record("read \(url.lastPathComponent)")
    return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
  }

  func write(_ data: Data, to url: URL) async throws {
    record("write \(url.lastPathComponent)")
    try data.write(to: url)
  }

  func fileExists(at url: URL) async -> Bool {
    record("exists \(url.lastPathComponent)")
    return FileManager.default.fileExists(atPath: url.path)
  }

  func discard(_ url: URL) async throws {
    record("discard \(url.lastPathComponent)")
    try FileManager.default.removeItem(at: url)
  }
}

@Suite struct TransportTests {
  @Test func runsGitAndReachesFilesThroughTheTransport() async throws {
    let temp = try await TempRepo()
    let transport = RecordingTransport()
    var runner = TempRepo.runner
    runner.transport = transport
    let repo = Repository(url: temp.root, runner: runner)
    #expect(repo.isRemote)

    try temp.write("a.txt", "one\n")
    try temp.write("new.txt", "two\nthree\n")
    try await repo.stage(["a.txt"])
    _ = try await repo.commit(message: "First")
    try temp.write("a.txt", "one\nmore\n")

    let status = try await repo.status()
    #expect(status.unstaged.map(\.path).sorted() == ["a.txt", "new.txt"])
    #expect(await repo.contents(of: "a.txt", at: .workingTree) == Data("one\nmore\n".utf8))
    let counts = try await repo.lineCounts(untracked: ["new.txt"])
    #expect(counts.unstaged["new.txt"]?.added == 2)

    try await repo.ignore("/ignored.log")
    #expect(try temp.read(".gitignore") == "/ignored.log\n")

    try await repo.discard(status.unstaged.filter { $0.kind == .untracked })
    #expect(!FileManager.default.fileExists(atPath: temp.root.appendingPathComponent("new.txt").path))

    let calls = transport.recorded
    #expect(calls.contains("git"))
    #expect(calls.contains("read a.txt"))
    #expect(calls.contains("read new.txt"))
    #expect(calls.contains("exists MERGE_HEAD"))
    #expect(calls.contains("write .gitignore"))
    #expect(calls.contains("discard new.txt"))
  }

  /// As the SSH transport runs it: the script as a shell's argument, the secrets ahead of git's own input on stdin.
  @Test(arguments: ["/bin/sh", "/bin/zsh", "/bin/bash"])
  func credentialsReachGitOverStdinInAShell(shell: String) async throws {
    let account = UUID().uuidString
    GitCredentials.set(GitCredential(username: "aiko", password: "token 'with' $pecial"), for: "example.test", account: account)
    defer { GitCredentials.set(nil, for: "example.test", account: account) }
    let environment = GitCredentials.environment(account: account)
    let secrets = GitCredentials.shellSecrets(in: environment)
    #expect(!secrets.script.contains("token"))
    #expect(!secrets.script.contains("aiko"))

    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-c", secrets.script + "exec git credential fill"]
    process.environment = ProcessInfo.processInfo.environment
      .merging(environment.filter { !GitCredentials.isSecret($0.key) }) { $1 }
      .merging(["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]) { $1 }
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: secrets.input + Data("protocol=https\nhost=example.test\n\n".utf8))
    try input.fileHandleForWriting.close()
    let filled = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(filled.contains("username=aiko\n"))
    #expect(filled.contains("password=token 'with' $pecial\n"))
  }

  /// Another machine gets a host's credentials only when one of the repository's remotes is on it.
  @Test func anotherMachineGetsOnlyItsRemotesCredentials() async throws {
    let account = UUID().uuidString
    GitCredentials.set(GitCredential(username: "local", password: "for-local"), for: "127.0.0.1", account: account)
    GitCredentials.set(GitCredential(username: "other", password: "for-other"), for: "other.test", account: account)
    defer {
      GitCredentials.set(nil, for: "127.0.0.1", account: account)
      GitCredentials.set(nil, for: "other.test", account: account)
    }
    func passwords(_ transport: RecordingTransport) -> Set<String> {
      Set(transport.environment.filter { $0.key.hasPrefix("GITKIT_PASSWORD_") }.values)
    }

    let temp = try await TempRepo()
    let transport = RecordingTransport()
    var runner = TempRepo.runner
    runner.transport = transport
    runner.credentialAccount = account
    let repo = Repository(url: temp.root, runner: runner)

    // Nothing listens on port 1: the fetch fails at once, after its environment went through the transport.
    try await repo.addRemote("origin", url: "https://127.0.0.1:1/repo.git")
    await #expect(throws: GitError.self) { try await repo.fetch() }
    #expect(passwords(transport) == ["for-local"])

    // Over SSH, none: git's helper is for HTTPS. A host that merely starts the same isn't that host either.
    let second = try await TempRepo()
    let secondTransport = RecordingTransport()
    var secondRunner = runner
    secondRunner.transport = secondTransport
    let ssh = Repository(url: second.root, runner: secondRunner)
    try await second.repo.git(["config", "core.sshCommand", "false"])
    try await ssh.addRemote("origin", url: "git@127.0.0.1:repo.git")
    try await ssh.addRemote("lookalike", url: "https://127.0.0.1.example.invalid:1/repo.git")
    await #expect(throws: GitError.self) { try await ssh.fetch() }
    #expect(passwords(secondTransport).isEmpty)

    // The address a switch to HTTPS checks counts, before any remote has it.
    await #expect(throws: GitError.self) {
      try await ssh.switchToHTTPS(HTTPSRemote(remote: "origin", host: "other.test", url: "https://other.test:1/repo.git"))
    }
    #expect(passwords(secondTransport) == ["for-other"])

    // Git on this machine keeps them all, as before: it's the app's own process that hands them over.
    #expect(GitCredentials.environment(account: account).filter { $0.key.hasPrefix("GITKIT_PASSWORD_") }.count == 2)
  }

  /// Above `useGit`, another machine gets the token only for a repository whose HTTPS offer the user accepted, and at
  /// `vaultKeyOnly` it runs nothing on the network.
  @Test func levelsDecideWhatAnotherMachineGets() async throws {
    let account = UUID().uuidString
    GitCredentials.set(GitCredential(username: "octo", password: "for-host"), for: "127.0.0.1", account: account)
    defer { GitCredentials.set(nil, for: "127.0.0.1", account: account) }
    func passwords(_ transport: RecordingTransport) -> Set<String> {
      Set(transport.environment.filter { $0.key.hasPrefix("GITKIT_PASSWORD_") }.values)
    }
    func at<T>(_ level: GitSecurityLevel, _ body: () async throws -> T) async rethrows -> T {
      try await GitNetwork.$scoped.withValue(GitNetwork.Configuration(engine: nil, level: { level })) { try await body() }
    }
    let temp = try await TempRepo()
    let transport = RecordingTransport()
    var runner = TempRepo.runner
    runner.transport = transport
    runner.credentialAccount = account
    let repo = Repository(url: temp.root, runner: runner)
    try await repo.addRemote("origin", url: "https://127.0.0.1:1/repo.git")

    await at(.useGit) { await #expect(throws: GitError.self) { try await repo.fetch() } }
    #expect(passwords(transport) == ["for-host"])

    for level in [GitSecurityLevel.inAppFirst, .sshOnly] {
      let plain = RecordingTransport()
      var runner = runner
      runner.transport = plain
      let repo = Repository(url: temp.root, runner: runner)
      await at(level) { await #expect(throws: GitError.self) { try await repo.fetch() } }
      #expect(passwords(plain).isEmpty)
    }

    let refused = RecordingTransport()
    var refusedRunner = runner
    refusedRunner.transport = refused
    let blocked = Repository(url: temp.root, runner: refusedRunner)
    await at(.vaultKeyOnly) {
      await #expect(throws: GitError.self) { try await blocked.fetch() }
      await #expect(throws: GitError.self) { try await blocked.pull() }
      await #expect(throws: GitError.self) { try await blocked.push() }
      await #expect(throws: GitError.self) {
        try await blocked.switchToHTTPS(HTTPSRemote(remote: "origin", host: "127.0.0.1", url: "https://127.0.0.1:1/r.git"))
      }
    }
    // A push reads the status first; nothing that talks to a remote ran.
    #expect(passwords(refused).isEmpty)
    #expect(refused.commands.allSatisfy { !["fetch", "pull", "push", "ls-remote", "clone"].contains($0) })

    // Accepting the offer lets the token through, for this machine and repository only.
    let accepting = RecordingTransport(machineID: "accepting-\(UUID().uuidString)")
    var acceptingRunner = runner
    acceptingRunner.transport = accepting
    let accepted = Repository(url: temp.root, runner: acceptingRunner)
    await at(.inAppFirst) {
      await #expect(throws: GitError.self) {
        try await accepted.switchToHTTPS(HTTPSRemote(remote: "origin", host: "127.0.0.1", url: "https://127.0.0.1:1/r.git"))
      }
      #expect(passwords(accepting) == ["for-host"])
      let next = RecordingTransport(machineID: accepting.machineID)
      var nextRunner = acceptingRunner
      nextRunner.transport = next
      await #expect(throws: GitError.self) { try await Repository(url: temp.root, runner: nextRunner).fetch() }
      #expect(passwords(next) == ["for-host"])
    }
  }

  @Test func failsWithGitsMessageAndTimesOut() async throws {
    let temp = try await TempRepo()
    var runner = TempRepo.runner
    runner.transport = RecordingTransport()
    let repo = Repository(url: temp.root, runner: runner)
    await #expect(throws: GitError.self) { try await repo.git(["not-a-command"]) }
    await #expect(throws: GitError.self) {
      try await repo.git(["-c", "alias.wait=!sleep 5", "wait"], timeout: .milliseconds(300))
    }
  }
}
