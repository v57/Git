import Foundation
import GitKit
import Testing

@testable import GitEngine

/// What the engine writes (objects, the index, refs, the working tree) is what git expects.
@Suite struct WritingTests {
  func baseRepo() throws -> Fixture {
    let fixture = try Fixture()
    try fixture.write("README.md", "# Demo\n")
    try fixture.write("src/a.swift", Fixture.lines(1...30))
    try fixture.write("src/b.swift", "let b = 1\n")
    try fixture.write("bin/tool.sh", "#!/bin/sh\necho hi\n")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: fixture.root.appendingPathComponent("bin/tool.sh").path)
    try fixture.commitAll("Initial commit")
    return fixture
  }

  @Test func stagesAndCommitsLikeGit() async throws {
    let fixture = try baseRepo()
    let engine = try fixture.engine
    try fixture.write("src/a.swift", Fixture.lines(1...31))
    try fixture.remove("src/b.swift")
    try fixture.write("docs/new.md", "new\n")
    try fixture.write("docs/deep/er.md", "deeper\n")
    try FileManager.default.createSymbolicLink(
      atPath: fixture.root.appendingPathComponent("link").path, withDestinationPath: "README.md")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: fixture.root.appendingPathComponent("bin/tool.sh").path)

    try await engine.stage(["src/a.swift", "src/b.swift", "docs", "link", "bin/tool.sh"])
    // git reads the engine's index the same way.
    #expect(normalized(try await engine.status()) == normalized(try await fixture.gitKit.status()))
    #expect(try porcelain(fixture).sorted() == [
      "A  docs/deep/er.md", "A  docs/new.md", "A  link", "D  src/b.swift", "M  bin/tool.sh", "M  src/a.swift",
    ])
    let sha = try await engine.commit(message: "Engine commit\n\nWith a body.  \n\n\n", author: Fixture.author)
    try fixture.git("fsck", "--strict", "--no-dangling")
    #expect(try fixture.git("rev-parse", "HEAD").trimmingCharacters(in: .newlines) == sha)
    #expect(try porcelain(fixture).isEmpty)
    let logged = try fixture.git("log", "-1", "--format=%an <%ae>%n%B")
    #expect(logged == "Engine <engine@example.com>\nEngine commit\n\nWith a body.\n\n")
    #expect(try fixture.git("diff", "HEAD~1", "--name-status").split(separator: "\n").count == 6)
    #expect(try fixture.git("reflog", "-1", "--format=%gs").hasPrefix("commit: Engine commit"))
    #expect(try await engine.status().isClean)
    // The commit's tree is git's tree for the same files.
    try fixture.git("read-tree", "HEAD")
    #expect(try fixture.git("write-tree") == (try fixture.git("rev-parse", "HEAD^{tree}")))
  }

  @Test func stageAllAndUnstage() async throws {
    let fixture = try baseRepo()
    let engine = try fixture.engine
    try fixture.write("README.md", "# Changed\n")
    try fixture.write("new.txt", "new\n")
    try fixture.write(".gitignore", "*.tmp\n")
    try fixture.write("junk.tmp", "junk\n")
    try fixture.remove("src/b.swift")
    try await engine.stageAll()
    #expect(try porcelain(fixture).sorted() == ["A  .gitignore", "A  new.txt", "D  src/b.swift", "M  README.md"])
    try await engine.unstage(["new.txt", "README.md"])
    #expect(Set(try porcelain(fixture)) == ["?? new.txt", "A  .gitignore", "D  src/b.swift", " M README.md"])
    #expect(normalized(try await engine.status()) == normalized(try await fixture.gitKit.status()))
    try await engine.unstageAll()
    #expect(Set(try porcelain(fixture)) == ["?? .gitignore", "?? new.txt", " D src/b.swift", " M README.md"])
    try fixture.git("fsck", "--strict")
  }

  @Test func discardsChanges() async throws {
    let fixture = try baseRepo()
    let engine = try fixture.engine
    try fixture.write("README.md", "# Changed\n")
    try fixture.remove("src/b.swift")
    try fixture.write("untracked/file.txt", "x\n")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: fixture.root.appendingPathComponent("bin/tool.sh").path)
    let status = try await engine.status()
    try await engine.discard(status.unstaged)
    #expect(try porcelain(fixture) == [])
    #expect(try fixture.read("README.md") == "# Demo\n")
    #expect(try fixture.read("src/b.swift") == "let b = 1\n")
    let attributes = try FileManager.default.attributesOfItem(
      atPath: fixture.root.appendingPathComponent("bin/tool.sh").path)
    #expect((attributes[.posixPermissions] as? Int ?? 0) & 0o111 != 0)
    #expect(!fixture.exists("untracked/file.txt"))
  }

  @Test func commitsOnAnUnbornBranchAndRefusesEmptyCommits() async throws {
    let fixture = try Fixture()
    let engine = try fixture.engine
    await #expect(throws: GitEngineError.self) { try await engine.commit(message: "Empty", author: Fixture.author) }
    try fixture.write("first.txt", "first\n")
    #expect(try await engine.log().isEmpty)
    #expect(try await engine.status().isUnborn)
    try await engine.stage(["first.txt"])
    #expect(try await engine.status().staged.map(\.kind) == [.added])
    let sha = try await engine.commit(message: "First", author: Fixture.author)
    #expect(try fixture.git("rev-list", "--count", "HEAD").trimmingCharacters(in: .newlines) == "1")
    #expect(try fixture.git("log", "-1", "--format=%H").trimmingCharacters(in: .newlines) == sha)
    try fixture.git("fsck", "--strict")
    await #expect(throws: GitEngineError.self) { try await engine.commit(message: "Again", author: Fixture.author) }
    await #expect(throws: GitEngineError.self) { try await engine.commit(message: "  \n", author: Fixture.author) }
    let log = try await engine.log()
    #expect(log.count == 1 && log[0].refs == [RefLabel(name: "main", kind: .localBranch, isCurrent: true)])
  }

  @Test func initializesARepositoryGitAccepts() async throws {
    let fixture = try Fixture(initialize: false)
    #expect(!LocalRepository.isRepository(fixture.root))
    #expect(throws: GitEngineError.self) { try LocalRepository(url: fixture.root) }
    let engine = try LocalRepository.initialize(at: fixture.root, initialBranch: "trunk")
    #expect(LocalRepository.isRepository(fixture.root))
    try fixture.write("a.txt", "a\n")
    try await engine.stageAll()
    _ = try await engine.commit(message: "Start", author: Fixture.author)
    #expect(try fixture.git("branch", "--show-current") == "trunk\n")
    try fixture.git("fsck", "--strict")
    try engine.setConfig("user.name", "Some One")
    try engine.setConfig("remote.origin.url", "https://example.com/x.git")
    #expect(engine.config("user.name") == "Some One")
    #expect(try fixture.git("config", "user.name") == "Some One\n")
    #expect(try fixture.git("config", "remote.origin.url") == "https://example.com/x.git\n")
    try engine.setConfig("user.name", nil)
    #expect(engine.config("user.name") == nil)
    try await engine.addRemote("upstream", url: "https://example.com/y.git")
    #expect(try await engine.remotes() == ["origin", "upstream"])
    #expect(try fixture.git("config", "remote.upstream.fetch") == "+refs/heads/*:refs/remotes/upstream/*\n")
  }

  @Test func createsAndSwitchesBranches() async throws {
    let fixture = try baseRepo()
    let engine = try fixture.engine
    try await engine.createBranch("feature")
    #expect(try fixture.git("branch", "--show-current") == "feature\n")
    try fixture.write("feature-only.txt", "feature\n")
    try fixture.write("src/a.swift", Fixture.lines(1...25))
    try fixture.remove("bin/tool.sh")
    try await engine.stageAll()
    _ = try await engine.commit(message: "Feature", author: Fixture.author)
    // An unrelated local change travels along.
    try fixture.write("README.md", "# Local edit\n")

    let main = try #require(try await engine.branches().first { $0.name == "main" })
    try await engine.switchTo(main)
    #expect(try fixture.git("branch", "--show-current") == "main\n")
    #expect(!fixture.exists("feature-only.txt"))
    #expect(fixture.exists("bin/tool.sh"))
    #expect(try fixture.read("src/a.swift") == Fixture.lines(1...30))
    #expect(try porcelain(fixture) == [" M README.md"])
    #expect(normalized(try await engine.status()) == normalized(try await fixture.gitKit.status()))

    // A local change to a file the switch rewrites stops it.
    try fixture.write("src/a.swift", "mine\n")
    let feature = try #require(try await engine.branches().first { $0.name == "feature" })
    await #expect(throws: GitEngineError.self) { try await engine.switchTo(feature) }
    #expect(try fixture.git("branch", "--show-current") == "main\n")
    #expect(try fixture.read("src/a.swift") == "mine\n")
    // An untracked file the other branch has stops it too.
    try fixture.write("src/a.swift", Fixture.lines(1...30))
    try fixture.write("feature-only.txt", "not the same\n")
    await #expect(throws: GitEngineError.self) { try await engine.switchTo(feature) }
    try fixture.remove("feature-only.txt")
    try await engine.switchTo(feature)
    #expect(try fixture.read("feature-only.txt") == "feature\n")
    #expect(try porcelain(fixture) == [" M README.md"])
    try fixture.git("fsck", "--strict")
    await #expect(throws: GitEngineError.self) { try await engine.createBranch("feature") }
    await #expect(throws: GitEngineError.self) { try await engine.createBranch("bad..name") }
    try await engine.createBranch("side", checkout: false)
    #expect(try fixture.git("branch", "--show-current") == "feature\n")
    #expect(try await engine.branches().map(\.name) == ["feature", "main", "side"])
  }

  /// The repository opened through a symlinked path (as `/var` is `/private/var`, on iOS too).
  @Test func worksThroughASymlinkedPath() async throws {
    let fixture = try baseRepo()
    let alias = fixture.sibling("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
    let engine = try LocalRepository(url: alias.appendingPathComponent("."))
    try fixture.write("dir/new.txt", "new\n")
    try fixture.remove("src/b.swift")
    try await engine.stageAll()
    _ = try await engine.commit(message: "Through the alias", author: Fixture.author)
    #expect(try await engine.status().isClean)
    try await engine.createBranch("side")
    try fixture.write("side.txt", "side\n")
    try await engine.stageAll()
    _ = try await engine.commit(message: "Side", author: Fixture.author)
    try await engine.switchTo(try #require(try await engine.branches().first { $0.name == "main" }))
    #expect(!fixture.exists("side.txt") && fixture.exists("dir/new.txt"))
    #expect(try await engine.branches().map(\.name) == ["main", "side"])
    #expect(try porcelain(fixture).isEmpty)
  }

  @Test func writtenObjectsAndIndexSurviveGitGC() async throws {
    let fixture = try baseRepo()
    let engine = try fixture.engine
    for round in 1...3 {
      try fixture.write("src/a.swift", Fixture.lines(1...(30 + round)))
      try await engine.stageAll()
      _ = try await engine.commit(message: "Round \(round)", author: Fixture.author)
    }
    try fixture.git("gc", "-q")
    try fixture.write("src/a.swift", "after gc\n")
    try await engine.stage(["src/a.swift"])
    _ = try await engine.commit(message: "After gc", author: Fixture.author)
    try fixture.git("fsck", "--strict")
    #expect(try fixture.git("rev-list", "--count", "HEAD") == "5\n")
    #expect(try await engine.log().map(\.subject) == ["After gc", "Round 3", "Round 2", "Round 1", "Initial commit"])
  }
}
