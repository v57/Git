import CryptoKit
import Foundation
import Testing

@testable import GitKit

/// The SSH agent git's `ssh` signs in through, with a key only this test holds, as the vault's is held by the Secure
/// Enclave. `ssh-add` and `ssh-keygen` are its clients; `GITKIT_SSH_TEST_PORT` and `GITKIT_SSH_TEST_AUTHORIZED_KEYS`
/// name a user-level sshd (see `../SSH/CLAUDE.md`) and its `AuthorizedKeysFile` for a real push.
@Suite(.serialized) struct GitSSHAgentTests {
  let key = P256.Signing.PrivateKey()

  var blob: Data {
    AgentMessage.string(Data("ecdsa-sha2-nistp256".utf8)) + AgentMessage.string(Data("nistp256".utf8))
      + AgentMessage.string(key.publicKey.x963Representation)
  }

  var keyLine: String { "ecdsa-sha2-nistp256 \(blob.base64EncodedString()) test-key" }

  func installIdentity(signed: (@Sendable () -> Void)? = nil) {
    let key = key
    let blob = blob
    GitSSHAgent.setIdentity {
      GitSSHAgent.Identity(publicKeyBlob: blob, comment: "test-key") { data in
        signed?()
        let raw = try key.signature(for: data).rawRepresentation
        return Self.mpint(raw.prefix(32)) + Self.mpint(raw.suffix(32))
      }
    }
  }

  static func mpint(_ bytes: Data) -> Data {
    var payload = Array(bytes.drop { $0 == 0 })
    if let first = payload.first, first & 0x80 != 0 { payload.insert(0, at: 0) }
    return AgentMessage.string(Data(payload))
  }

  func run(_ tool: String, _ arguments: [String], agent: [String: String]) throws -> (output: String, status: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(agent) { $1 }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), process.terminationStatus)
  }

  @Test func listsItsKeyFirstAndGoesAwayWithTheCommand() async throws {
    installIdentity()
    defer { GitSSHAgent.setIdentity(nil) }
    let socket = try await GitSSHAgent.serving(isLocal: true) { agent in
      let listed = try run("/usr/bin/ssh-add", ["-L"], agent: agent)
      #expect(listed.status == 0)
      #expect(listed.output.hasPrefix(keyLine))
      return try #require(agent["SSH_AUTH_SOCK"])
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(!FileManager.default.fileExists(atPath: socket))
  }

  @Test func signsOnlyLogins() async throws {
    installIdentity()
    defer { GitSSHAgent.setIdentity(nil) }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let publicKey = folder.appendingPathComponent("key.pub")
    let message = folder.appendingPathComponent("message")
    try keyLine.write(to: publicKey, atomically: true, encoding: .utf8)
    try "text".write(to: message, atomically: true, encoding: .utf8)
    try await GitSSHAgent.serving(isLocal: true) { agent in
      // A signature on a file is what a commit signature is, and the key doesn't make those.
      let result = try run(
        "/usr/bin/ssh-keygen", ["-Y", "sign", "-n", "git", "-f", publicKey.path, message.path], agent: agent)
      #expect(result.status != 0)
    }
    #expect(!FileManager.default.fileExists(atPath: message.path + ".sig"))
    #expect(AgentMessage.isLogin([0, 0, 0, 1, 9, 50, 0]))
    #expect(!AgentMessage.isLogin([0, 0, 0, 1, 9, 49, 0]))
    #expect(!AgentMessage.isLogin([0, 0, 0, 9, 9]))
    #expect(!AgentMessage.isLogin(Array("SSHSIG".utf8)))
  }

  @Test func addsNothingForGitOnAnotherMachineOrWithoutAKey() async throws {
    #expect(try await GitSSHAgent.serving(isLocal: true) { $0 } == [:])
    installIdentity()
    defer { GitSSHAgent.setIdentity(nil) }
    #expect(try await GitSSHAgent.serving(isLocal: false) { $0 } == [:])
  }

  @Test func leavesTheUsersOwnSSHCommandAlone() async throws {
    let repository = try await TempRepo()
    #expect(await Repository.newHostKeys(runner: TempRepo.runner, in: repository.root)["GIT_SSH_COMMAND"] != nil)
    try await TempRepo.runner.run(["config", "core.sshCommand", "my-ssh"], in: repository.root)
    #expect(await Repository.newHostKeys(runner: TempRepo.runner, in: repository.root) == [:])
  }

  /// Clone, push and fetch by git's own `ssh`, signing in with nothing but the agent's key.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["GITKIT_SSH_TEST_PORT"] != nil))
  func gitPushesOverSSHWithTheKey() async throws {
    let environment = ProcessInfo.processInfo.environment
    let port = try #require(environment["GITKIT_SSH_TEST_PORT"])
    let authorized = URL(fileURLWithPath: try #require(environment["GITKIT_SSH_TEST_AUTHORIZED_KEYS"]))
    let before = try String(contentsOf: authorized, encoding: .utf8)
    try (before + keyLine + "\n").write(to: authorized, atomically: true, encoding: .utf8)
    defer { try? before.write(to: authorized, atomically: true, encoding: .utf8) }

    final class Count: @unchecked Sendable {
      private let lock = NSLock()
      private var value = 0
      func add() { lock.withLock { value += 1 } }
      var current: Int { lock.withLock { value } }
    }
    let signatures = Count()
    installIdentity { signatures.add() }
    defer { GitSSHAgent.setIdentity(nil) }

    let bare = try await TempRepo(bare: true)
    let parent = bare.root.deletingLastPathComponent()
    // Nothing of the user's: no known hosts or key files, and the agent is the only way in.
    let hosts = parent.appendingPathComponent("known_hosts").path
    let runner = GitRunner(extraEnvironment: TempRepo.runner.extraEnvironment.merging([
      "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.sshCommand",
      "GIT_CONFIG_VALUE_0": "ssh -F /dev/null -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=\(hosts) -o IdentityFile=/dev/null",
    ]) { $1 })

    let url = "ssh://\(NSUserName())@127.0.0.1:\(port)\(bare.root.path)"
    let clone = try await Repository.clone(url, to: parent.appendingPathComponent("clone"), runner: runner)
    #expect(signatures.current >= 1)
    try "hello\n".write(to: clone.url.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try await runner.run(["add", "file.txt"], in: clone.url)
    try await runner.run(["commit", "-qm", "First"], in: clone.url)
    let signedBefore = signatures.current
    try await clone.push()
    #expect(signatures.current > signedBefore)
    let head = try await runner.run(["rev-parse", "HEAD"], in: clone.url).output
    let branch = try await runner.run(["branch", "--show-current"], in: clone.url).output
      .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(try await runner.run(["rev-parse", "refs/heads/\(branch)"], in: bare.root).output == head)
    try await clone.fetch()

    // Someone else's key gets nowhere.
    let other = P256.Signing.PrivateKey()
    let otherBlob =
      AgentMessage.string(Data("ecdsa-sha2-nistp256".utf8)) + AgentMessage.string(Data("nistp256".utf8))
      + AgentMessage.string(other.publicKey.x963Representation)
    GitSSHAgent.setIdentity {
      GitSSHAgent.Identity(publicKeyBlob: otherBlob, comment: "other") { data in
        let raw = try other.signature(for: data).rawRepresentation
        return Self.mpint(raw.prefix(32)) + Self.mpint(raw.suffix(32))
      }
    }
    // The agent the tests run under may hold the user's keys: only this one here.
    await #expect(throws: GitError.self) {
      try await runner.run(
        ["ls-remote", url], in: clone.url,
        environment: ["SSH_AUTH_SOCK": "/nonexistent"])
    }
  }
}
