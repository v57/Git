import Foundation
import Testing

@testable import GitKit

@Suite struct RunnerStressTests {
  /// Many git calls at once, each with more output than a pipe buffer holds, must all finish:
  /// this is what happens when a file watcher refreshes dozens of repositories together.
  @Test(.timeLimit(.minutes(1))) func manyConcurrentCallsWithLargeOutputFinish() async throws {
    let temp = try await TempRepo()
    try temp.write("big.txt", String(repeating: "a line of text that is long enough\n", count: 6000))
    try await temp.commitAll("big")
    let repo = temp.repo
    let sizes = try await withThrowingTaskGroup(of: Int.self) { group in
      for _ in 0..<150 {
        group.addTask { try await repo.git(["show", "HEAD"]).stdout.count }
      }
      return try await group.reduce(into: []) { $0.append($1) }
    }
    #expect(sizes.count == 150)
    #expect(sizes.allSatisfy { $0 > 100_000 })
  }
}

@Suite struct RunnerTimeoutTests {
  @Test func timeoutStopsGit() async throws {
    let temp = try await TempRepo()
    let clock = ContinuousClock()
    let start = clock.now
    await #expect(throws: GitError.self) {
      try await temp.repo.git(
        ["-c", "alias.wait=!sleep 30", "wait"], timeout: .milliseconds(500))
    }
    #expect(clock.now - start < .seconds(10))
  }
}
