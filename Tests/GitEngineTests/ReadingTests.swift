import Foundation
import GitKit
import Testing

@testable import GitEngine

/// The engine reads repositories git made the way GitKit (running git) reads them.
@Suite struct ReadingTests {
  /// A repository with history on two branches, a tag, renames and a file changed enough times to delta well.
  func historyRepo() throws -> Fixture {
    let fixture = try Fixture()
    try fixture.write("README.md", "# Demo\n\nSome text.\n")
    try fixture.write("src/main.swift", Fixture.lines(1...200))
    try fixture.write("src/util/helpers.swift", "func helper() {}\n")
    try fixture.commitAll("Initial commit")
    for round in 1...6 {
      var text = Fixture.lines(1...200)
      text = text.replacingOccurrences(of: "line \(round * 20)\n", with: "changed \(round)\n")
      try fixture.write("src/main.swift", text)
      try fixture.write("notes/round\(round).txt", "round \(round)\n")
      try fixture.commitAll("Round \(round)\n\nBody of round \(round).\nSecond line.")
    }
    try fixture.git("tag", "-a", "v1", "-m", "Version 1")
    try fixture.git("tag", "light")
    try fixture.git("switch", "-q", "-c", "feature")
    try fixture.git("mv", "src/util/helpers.swift", "src/util/tools.swift")
    try fixture.write("feature.txt", "feature\n")
    try fixture.commitAll("Feature work")
    try fixture.git("switch", "-q", "main")
    return fixture
  }

  func compareHistory(_ fixture: Fixture) async throws {
    let engine = try fixture.engine
    for revision in [nil, "feature", "v1", "main~2"] as [String?] {
      let ours = try await engine.log(revision: revision)
      let theirs = try await fixture.gitKit.log(LogQuery(revision: revision))
      #expect(ours.map(\.id) == theirs.map(\.id))
      for (a, b) in zip(ours, theirs) {
        #expect(a.parents == b.parents)
        #expect(a.subject == b.subject)
        #expect(a.body == b.body)
        #expect(a.authorName == b.authorName && a.authorEmail == b.authorEmail)
        #expect(a.authorDate == b.authorDate && a.committerDate == b.committerDate)
        #expect(Set(a.refs) == Set(b.refs), "\(a.subject)")
      }
    }
    let paged = try await engine.log(skip: 2, limit: 3)
    #expect(paged.map(\.id) == (try await fixture.gitKit.log(skip: 2, limit: 3)).map(\.id))

    for commit in try await fixture.gitKit.log(LogQuery(revision: "feature")) {
      let ours = try await engine.changedFiles(in: commit)
      let theirs = try await fixture.gitKit.changedFiles(in: commit)
      #expect(ours == theirs, "\(commit.subject)")
      for file in theirs {
        let target = DiffTarget.commit(
          sha: commit.id, parent: commit.parents.first, path: file.path, originalPath: file.originalPath)
        let ourDiff = try await engine.diff(target)
        let theirDiff = try await fixture.gitKit.diff(target)
        #expect(ourDiff == theirDiff, "\(commit.subject) \(file.path)")
      }
    }
    let ourBranches = try await engine.branches()
    let theirBranches = try await fixture.gitKit.branches()
    #expect(ourBranches == theirBranches)
    let tools = await engine.contents(of: "src/util/tools.swift", at: .commit("feature"))
    #expect(tools == Data("func helper() {}\n".utf8))
    #expect(await engine.contents(of: "missing", at: .commit("HEAD")) == nil)
  }

  @Test func readsLooseHistory() async throws {
    try await compareHistory(historyRepo())
  }

  @Test func readsPackedHistoryWithDeltas() async throws {
    let fixture = try historyRepo()
    try fixture.git("gc", "-q", "--aggressive")
    let verify = try fixture.git(
      "verify-pack", "-v",
      try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent(".git/objects/pack").path)
        .first { $0.hasSuffix(".idx") }.map { ".git/objects/pack/" + $0 } ?? "")
    #expect(verify.contains("chain length = 1"))
    #expect(!fixture.exists(".git/refs/tags/v1"))  // packed-refs, with a peeled line for the tag
    try await compareHistory(fixture)
  }

  @Test func statusMatchesGit() async throws {
    let fixture = try historyRepo()
    try fixture.write("README.md", "# Demo\n\nChanged.\n")
    try fixture.git("add", "README.md")
    try fixture.write("README.md", "# Demo\n\nChanged twice.\n")
    try fixture.write("new/deep/file.txt", "new\n")
    try fixture.write("staged-new.txt", "staged\n")
    try fixture.git("add", "staged-new.txt")
    try fixture.remove("notes/round1.txt")
    try fixture.git("rm", "-q", "notes/round2.txt")
    try fixture.git("mv", "notes/round3.txt", "notes/moved.txt")
    try fixture.write("src/main.swift", Fixture.lines(1...199))
    try fixture.git("add", "src/main.swift")
    try fixture.git("mv", "src/main.swift", "src/app.swift")
    let script = fixture.root.appendingPathComponent("notes/round4.txt")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    try FileManager.default.createSymbolicLink(
      atPath: fixture.root.appendingPathComponent("link").path, withDestinationPath: "README.md")

    let ours = try await fixture.engine.status()
    let theirs = try await fixture.gitKit.status()
    #expect(normalized(ours) == normalized(theirs))
    // A second run reads the refreshed stat data git or the engine wrote.
    #expect(normalized(try await fixture.engine.status()) == normalized(theirs))

    for change in theirs.unstaged {
      let target = DiffTarget.unstaged(path: change.path, untracked: change.kind == .untracked)
      #expect(try await fixture.engine.diff(target) == (try await fixture.gitKit.diff(target)), "\(change.path)")
    }
    for change in theirs.staged {
      let target = DiffTarget.staged(path: change.path, originalPath: change.originalPath)
      let ours = try await fixture.engine.diff(target)
      let theirs = try await fixture.gitKit.diff(target)
      #expect(ours == theirs, "\(change.path)")
    }
  }

  @Test func statusWithUpstreamAndDetachedHead() async throws {
    let fixture = try historyRepo()
    let remote = fixture.sibling("remote.git")
    try git(["clone", "-q", "--bare", fixture.root.path, remote.path], in: fixture.parent)
    try fixture.git("remote", "add", "origin", remote.path)
    try fixture.git("fetch", "-q", "origin")
    try fixture.git("branch", "-q", "--set-upstream-to=origin/main")
    try fixture.write("a.txt", "a\n")
    try fixture.commitAll("Ahead")
    try fixture.git("update-ref", "refs/remotes/origin/main", "main~2")
    #expect(normalized(try await fixture.engine.status()) == normalized(try await fixture.gitKit.status()))
    #expect(try await fixture.engine.branches() == (try await fixture.gitKit.branches()))
    #expect(try await fixture.engine.remotes() == ["origin"])
    #expect(try await fixture.engine.remoteURL("origin") == remote.path)
    try fixture.git("switch", "-q", "--detach", "HEAD~1")
    let status = try await fixture.engine.status()
    #expect(status.branch == nil && status.isDetached)
    #expect(normalized(status) == normalized(try await fixture.gitKit.status()))
    let log = try await fixture.engine.log(limit: 1)
    #expect(log.first?.refs.first == RefLabel(name: "HEAD", kind: .head, isCurrent: true))
  }

  @Test func readsIndexVersion4() async throws {
    let fixture = try historyRepo()
    try fixture.git("update-index", "--index-version", "4")
    try fixture.write("src/util/tools.swift", "changed\n")
    try fixture.write("README.md", "changed\n")
    #expect(normalized(try await fixture.engine.status()) == normalized(try await fixture.gitKit.status()))
  }

  @Test func ignoreRulesMatchGit() async throws {
    let fixture = try Fixture()
    try fixture.write(
      ".gitignore",
      """
      # comment
      *.log
      !keep.log
      /root-only.txt
      build/
      **/generated/**
      docs/**/*.tmp
      cache?/
      [Tt]emp*
      \\#hash
      trailing.txt
      a/**/z.txt

      """)
    try fixture.write("nested/.gitignore", "*.local\n!important.local\nsub/\n")
    try fixture.write(".git/info/exclude", "excluded.txt\n")
    for path in [
      "app.log", "keep.log", "dir/other.log", "dir/keep.log", "root-only.txt", "dir/root-only.txt", "build/out.o",
      "src/build/x.o", "build.txt", "src/generated/a/b.swift", "generated/top.txt", "docs/a/b/c.tmp", "docs/c.tmp",
      "other/docs/c.tmp", "cache1/x", "cache12/x", "Temp.txt", "temp/x", "tempo.txt", "#hash", "trailing.txt",
      "a/z.txt", "a/b/c/z.txt", "nested/x.local", "nested/important.local", "nested/sub/file", "nested/sub.txt",
      "excluded.txt", "dir/excluded.txt", "plain.txt", "dir/plain.txt", "empty/.keep",
    ] {
      try fixture.write(path, "x\n")
    }
    try FileManager.default.createDirectory(
      at: fixture.root.appendingPathComponent("empty-dir"), withIntermediateDirectories: true)
    let ours = try await fixture.engine.status().unstaged.map(\.path).sorted()
    let theirs = try await fixture.gitKit.status().unstaged.map(\.path).sorted()
    #expect(ours == theirs)
  }

  @Test func showsNestedRepositoryAsFolder() async throws {
    let fixture = try Fixture()
    try fixture.write("top.txt", "x\n")
    let nested = fixture.root.appendingPathComponent("inner")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try git(["init", "-q"], in: nested)
    try Data("y\n".utf8).write(to: nested.appendingPathComponent("y.txt"))
    #expect(normalized(try await fixture.engine.status()) == normalized(try await fixture.gitKit.status()))
  }

  @Test func diffsMatchGit() async throws {
    let fixture = try Fixture()
    let base = Fixture.lines(1...60)
    let cases: [String: (String, String)] = [
      "middle.txt": (base, base.replacingOccurrences(of: "line 30\n", with: "line thirty\nextra\n")),
      "twoHunks.txt": (base, replacing(base, ["line 5\n": "", "line 50\n": "fifty\n"])),
      "merged.txt": (base, replacing(base, ["line 10\n": "ten\n", "line 16\n": "sixteen\n"])),
      "start.txt": (base, "first\n" + base),
      "end.txt": (base, base + "last\n"),
      "noNewline.txt": ("a\nb\nc", "a\nb\nc\nd"),
      "noNewlineBoth.txt": ("a\nb\nc", "a\nB\nc"),
      "addNewline.txt": ("a\nb", "a\nb\n"),
      "func.swift": (
        "import Foundation\n\nfunc first() {\n" + Fixture.lines(1...10, "  let a") + "}\n",
        "import Foundation\n\nfunc first() {\n" + replacing(Fixture.lines(1...10, "  let a"), ["a 8": "b 8"]) + "}\n"
      ),
      "emptied.txt": ("one\ntwo\n", ""),
      "fromEmpty.txt": ("", "one\n"),
      "binary.bin": ("abc\u{0}def", "abc\u{0}xyz"),
      "slide.txt": ("a\nb\nb\nb\nc\n", "a\nb\nb\nb\nb\nc\n"),
    ]
    for (name, sides) in cases { try fixture.write(name, sides.0) }
    try fixture.commitAll("Base")
    for (name, sides) in cases { try fixture.write(name, sides.1) }
    for name in cases.keys.sorted() {
      let target = DiffTarget.unstaged(path: name, untracked: false)
      let ours = try await fixture.engine.diff(target)
      let theirs = try await fixture.gitKit.diff(target)
      #expect(ours == theirs, "\(name)")
    }
    let unchanged = try await fixture.engine.diff(.unstaged(path: "nothing.txt", untracked: false))
    #expect(unchanged == nil)
  }

  /// Lines keep their `\r` (GitKit's parser splits Swift strings on `\n`, which doesn't split `\r\n`, so this
  /// isn't compared with it).
  @Test func keepsCarriageReturns() async throws {
    let fixture = try Fixture()
    try fixture.write("crlf.txt", "a\r\nb\r\nc\r\n")
    try fixture.commitAll("Base")
    try fixture.write("crlf.txt", "a\r\nB\r\nc\r\n")
    let diff = try #require(try await fixture.engine.diff(.unstaged(path: "crlf.txt", untracked: false)))
    #expect(diff.hunks.count == 1)
    #expect(diff.lines.map(\.text) == ["a\r", "b\r", "B\r", "c\r"])
    #expect(diff.lines.map(\.kind) == [.context, .removed, .added, .context])
  }

  @Test func randomDiffsMatchGit() async throws {
    let fixture = try Fixture()
    var generator = SeededGenerator(seed: 42)
    var mismatches = 0
    for round in 0..<40 {
      let words = ["alpha", "beta", "", "gamma", "}", "{", "delta", "return x"]
      let old = (0..<Int.random(in: 5...80, using: &generator)).map { _ in words.randomElement(using: &generator)! }
      var new = old
      for _ in 0..<Int.random(in: 1...8, using: &generator) {
        let position = Int.random(in: 0...new.count, using: &generator)
        switch Int.random(in: 0...2, using: &generator) {
        case 0: new.insert(words.randomElement(using: &generator)!, at: position)
        case 1: if position < new.count { new.remove(at: position) }
        default: if position < new.count { new[position] = "changed \(round)" }
        }
      }
      let name = "random\(round).txt"
      try fixture.write(name, old.joined(separator: "\n") + "\n")
      try fixture.git("add", name)
      try fixture.write(name, new.joined(separator: "\n") + "\n")
      let target = DiffTarget.unstaged(path: name, untracked: false)
      let ours = try await fixture.engine.diff(target)
      let theirs = try await fixture.gitKit.diff(target)
      #expect(ours?.additions == theirs?.additions && ours?.deletions == theirs?.deletions)
      if ours != theirs { mismatches += 1 }
    }
    // Ambiguous changes may be placed differently (git's indent heuristic); most must match exactly.
    #expect(mismatches <= 8, "\(mismatches) of 40 random diffs differ from git's")
  }
}

func replacing(_ text: String, _ replacements: [String: String]) -> String {
  replacements.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
}

/// A small deterministic random number generator for reproducible tests.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return state
  }
}
