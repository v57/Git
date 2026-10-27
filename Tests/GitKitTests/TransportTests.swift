import Foundation
import Testing

@testable import GitKit

/// A transport that runs this machine's git and counts what goes through it, standing in for git on another
/// machine (the iOS app's SSH transport).
final class RecordingTransport: GitTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [String] = []
  let runner = TempRepo.runner

  var recorded: [String] { lock.withLock { calls } }

  private func record(_ call: String) { lock.withLock { calls.append(call) } }

  func run(
    _ arguments: [String], in directory: URL?, input: Data?, environment: [String: String],
    progress: (@Sendable (String) -> Void)?
  ) async throws -> GitResult {
    record("git")
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
