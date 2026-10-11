import Foundation
import Testing

@testable import GitKit

/// A throwaway repository isolated from the user's git config.
struct TempRepo {
  static let runner = GitRunner(extraEnvironment: [
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ])

  let root: URL
  let repo: Repository

  init(bare: Bool = false, in parent: URL? = nil) async throws {
    let parent =
      parent
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "GitKitTests-\(UUID().uuidString)")
    root = parent.appendingPathComponent(bare ? "remote.git" : "repo")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await Self.runner.run(bare ? ["init", "-q", "--bare", "-b", "main"] : ["init", "-q", "-b", "main"], in: root)
    repo = Repository(url: root, runner: Self.runner)
  }

  init(cloning remote: URL, name: String) async throws {
    let parent = remote.deletingLastPathComponent()
    root = parent.appendingPathComponent(name)
    try await Self.runner.run(["clone", "-q", remote.path, root.path], in: parent)
    repo = Repository(url: root, runner: Self.runner)
  }

  func write(_ path: String, _ text: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  func read(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
  }

  func index(_ path: String) async throws -> String {
    try await repo.git(["show", ":\(path)"]).output
  }

  func commitAll(_ message: String) async throws {
    try await repo.stageAll()
    try await repo.commit(message: message)
  }

  static func lines(_ range: ClosedRange<Int>) -> String {
    range.map { "line \($0)\n" }.joined()
  }
}

@Suite struct LineStagingTests {
  /// 20 lines with lines 2 and 15 changed: two hunks.
  func twoHunkRepo() async throws -> TempRepo {
    let temp = try await TempRepo()
    try temp.write("f.txt", TempRepo.lines(1...20))
    try await temp.commitAll("init")
    try temp.write(
      "f.txt",
      TempRepo.lines(1...20).replacingOccurrences(of: "line 2\n", with: "LINE 2\n")
        .replacingOccurrences(of: "line 15\n", with: "LINE 15\n"))
    return temp
  }

  func changedIDs(_ diff: FileDiff, containing text: String) -> Set<Int> {
    Set(diff.lines.filter { $0.isChange && $0.text.contains(text) }.map(\.id))
  }

  @Test func stagesSelectedLines() async throws {
    let temp = try await twoHunkRepo()
    let diff = try #require(try await temp.repo.diff(.unstaged(path: "f.txt", untracked: false)))
    #expect(diff.hunks.count == 2)
    try await temp.repo.stageLines(changedIDs(diff, containing: "15"), of: diff)

    let staged = try #require(try await temp.repo.diff(.staged(path: "f.txt", originalPath: nil)))
    #expect(staged.lines.filter(\.isChange).map(\.text) == ["line 15", "LINE 15"])
    let unstaged = try #require(try await temp.repo.diff(.unstaged(path: "f.txt", untracked: false)))
    #expect(unstaged.lines.filter(\.isChange).map(\.text) == ["line 2", "LINE 2"])
  }

  @Test func stagesOnlyTheAddedHalfOfAChange() async throws {
    let temp = try await twoHunkRepo()
    let diff = try #require(try await temp.repo.diff(.unstaged(path: "f.txt", untracked: false)))
    let added = Set(diff.lines.filter { $0.kind == .added && $0.text == "LINE 2" }.map(\.id))
    try await temp.repo.stageLines(added, of: diff)
    #expect(try await temp.index("f.txt").hasPrefix("line 1\nline 2\nLINE 2\nline 3\n"))
  }

  @Test func unstagesSelectedLines() async throws {
    let temp = try await twoHunkRepo()
    try await temp.repo.stageAll()
    let staged = try #require(try await temp.repo.diff(.staged(path: "f.txt", originalPath: nil)))
    try await temp.repo.unstageLines(changedIDs(staged, containing: "2"), of: staged)

    let index = try await temp.index("f.txt")
    #expect(index.contains("line 2\n") && index.contains("LINE 15\n"))
    #expect(try temp.read("f.txt").contains("LINE 2\n"))
  }

  @Test func discardsSelectedLines() async throws {
    let temp = try await twoHunkRepo()
    let diff = try #require(try await temp.repo.diff(.unstaged(path: "f.txt", untracked: false)))
    try await temp.repo.discardLines(changedIDs(diff, containing: "2"), of: diff)
    let text = try temp.read("f.txt")
    #expect(text.contains("line 2\n") && text.contains("LINE 15\n"))
  }

  @Test func stagesPartOfAnUntrackedFile() async throws {
    let temp = try await TempRepo()
    try temp.write("a.txt", "a\n")
    try await temp.commitAll("init")
    try temp.write("new file.txt", "one\ntwo\nthree\n")
    let diff = try #require(
      try await temp.repo.diff(.unstaged(path: "new file.txt", untracked: true)))
    #expect(diff.isNewFile && diff.path == "new file.txt")
    let ids = Set(diff.lines.filter { $0.text != "three" }.map(\.id))
    try await temp.repo.stageLines(ids, of: diff)
    #expect(try await temp.index("new file.txt") == "one\ntwo\n")

    // Then unstage "two" from the staged new file.
    let staged = try #require(
      try await temp.repo.diff(.staged(path: "new file.txt", originalPath: nil)))
    #expect(staged.isNewFile)
    try await temp.repo.unstageLines(changedIDs(staged, containing: "two"), of: staged)
    #expect(try await temp.index("new file.txt") == "one\n")
  }

  @Test func discardsPartOfAnUntrackedFile() async throws {
    let temp = try await TempRepo()
    try temp.write("a.txt", "a\n")
    try await temp.commitAll("init")
    try temp.write("n.txt", "keep\ndrop\n")
    let diff = try #require(try await temp.repo.diff(.unstaged(path: "n.txt", untracked: true)))
    try await temp.repo.discardLines(changedIDs(diff, containing: "drop"), of: diff)
    #expect(try temp.read("n.txt") == "keep\n")
  }

  @Test func stagesPartOfADeletion() async throws {
    let temp = try await TempRepo()
    try temp.write("d.txt", "one\ntwo\nthree\n")
    try await temp.commitAll("init")
    try FileManager.default.removeItem(at: temp.root.appendingPathComponent("d.txt"))
    let diff = try #require(try await temp.repo.diff(.unstaged(path: "d.txt", untracked: false)))
    #expect(diff.isDeletedFile)
    try await temp.repo.stageLines(changedIDs(diff, containing: "one"), of: diff)
    #expect(try await temp.index("d.txt") == "two\nthree\n")

    // Staging the rest deletes it from the index.
    let rest = try #require(try await temp.repo.diff(.unstaged(path: "d.txt", untracked: false)))
    try await temp.repo.stageLines(Set(rest.lines.filter(\.isChange).map(\.id)), of: rest)
    let status = try await temp.repo.status()
    #expect(status.staged.first?.kind == .deleted && status.unstaged.isEmpty)
  }

  @Test func keepsLineOrderWhenSplittingAReplacement() async throws {
    let temp = try await TempRepo()
    try temp.write("f.txt", "a\nb\n")
    try await temp.commitAll("init")
    try temp.write("f.txt", "A\nB\n")
    let diff = try #require(try await temp.repo.diff(.unstaged(path: "f.txt", untracked: false)))
    let firstPair = Set(diff.lines.filter { $0.text.lowercased() == "a" }.map(\.id))
    try await temp.repo.stageLines(firstPair, of: diff)
    #expect(try await temp.index("f.txt") == "A\nb\n")

    // Stage everything, then unstage only the b -> B replacement.
    try await temp.repo.stageAll()
    let staged = try #require(try await temp.repo.diff(.staged(path: "f.txt", originalPath: nil)))
    let secondPair = Set(staged.lines.filter { $0.text.lowercased() == "b" }.map(\.id))
    try await temp.repo.unstageLines(secondPair, of: staged)
    #expect(try await temp.index("f.txt") == "A\nb\n")
  }

  @Test func handlesMissingTrailingNewline() async throws {
    let temp = try await TempRepo()
    try temp.write("f.txt", "a\nb")
    try await temp.commitAll("init")
    try temp.write("f.txt", "A\nb\nc")
    let diff = try #require(try await temp.repo.diff(.unstaged(path: "f.txt", untracked: false)))
    let ids = Set(diff.lines.filter { $0.isChange && $0.text.lowercased() == "a" }.map(\.id))
    try await temp.repo.stageLines(ids, of: diff)
    let index = try await temp.index("f.txt")
    #expect(index == "A\nb")
  }
}

@Suite struct RepositoryTests {
  @Test func statusLogAndCommitFiles() async throws {
    let temp = try await TempRepo()
    let empty = try await temp.repo.status()
    #expect(empty.isUnborn && empty.branch == "main")
    #expect(try await temp.repo.log().isEmpty)

    try temp.write("a.txt", "a\n")
    try temp.write("dir/b.txt", "b\n")
    try await temp.commitAll("First\n\nBody text")
    try temp.write("a.txt", "a2\n")
    try await temp.repo.git(["mv", "dir/b.txt", "dir/c.txt"])
    try await temp.commitAll("Second")

    let commits = try await temp.repo.log()
    #expect(commits.map(\.subject) == ["Second", "First"])
    #expect(commits[1].body == "Body text" && commits[1].parents.isEmpty)
    #expect(commits[0].refs.first?.name == "main" && commits[0].refs.first?.isCurrent == true)

    let files = try await temp.repo.changedFiles(in: commits[0])
    #expect(files.map(\.path) == ["a.txt", "dir/c.txt"])
    #expect(files[1].kind == .renamed && files[1].originalPath == "dir/b.txt")
    let rootFiles = try await temp.repo.changedFiles(in: commits[1])
    #expect(rootFiles.map(\.path) == ["a.txt", "dir/b.txt"])

    let commitDiff = try #require(
      try await temp.repo.diff(
        .commit(sha: commits[1].id, parent: nil, path: "a.txt", originalPath: nil)))
    #expect(commitDiff.isNewFile && commitDiff.lines.first?.text == "a")

    let found = try await temp.repo.log(LogQuery(search: "FIRST"))
    #expect(found.map(\.subject) == ["First"])
    let bySha = try await temp.repo.log(LogQuery(search: commits[1].shortID, searchField: .sha))
    #expect(bySha.map(\.id) == [commits[1].id])
    #expect(try await temp.repo.lastCommitMessage() == "Second")
  }

  @Test func unstagesBeforeFirstCommit() async throws {
    let temp = try await TempRepo()
    try temp.write("a.txt", "a\n")
    try await temp.repo.stage(["a.txt"])
    #expect(try await temp.repo.status().staged.count == 1)
    try await temp.repo.unstage(["a.txt"])
    let status = try await temp.repo.status()
    #expect(status.staged.isEmpty && status.unstaged.first?.kind == .untracked)
  }

  @Test func branchesAndStashes() async throws {
    let temp = try await TempRepo()
    try temp.write("a.txt", "a\n")
    try await temp.commitAll("init")
    #expect(await temp.repo.isValidBranchName("feature/x"))
    #expect(!(await temp.repo.isValidBranchName("bad..name")))
    try await temp.repo.createBranch("feature/x")
    #expect(try await temp.repo.status().branch == "feature/x")
    let branches = try await temp.repo.branches()
    #expect(branches.map(\.name) == ["feature/x", "main"])
    try await temp.repo.switchTo(try #require(branches.first { $0.name == "main" }))
    #expect(try await temp.repo.status().branch == "main")

    try temp.write("a.txt", "changed\n")
    try temp.write("u.txt", "untracked\n")
    try await temp.repo.stash(message: "work")
    #expect(try await temp.repo.status().isClean)
    let stashes = try await temp.repo.stashes()
    #expect(stashes.count == 1 && stashes[0].message.contains("work"))
    try await temp.repo.popStash(stashes[0])
    #expect(try temp.read("a.txt") == "changed\n")
    #expect(try temp.read("u.txt") == "untracked\n")
    #expect(try await temp.repo.stashes().isEmpty)
  }

  @Test func discardMovesUntrackedFilesToTrash() async throws {
    let temp = try await TempRepo()
    try temp.write("a.txt", "a\n")
    try await temp.commitAll("init")
    try temp.write("a.txt", "b\n")
    try temp.write("junk.txt", "junk\n")
    let status = try await temp.repo.status()
    try await temp.repo.discard(status.unstaged)
    #expect(try temp.read("a.txt") == "a\n")
    #expect(!FileManager.default.fileExists(atPath: temp.root.appendingPathComponent("junk.txt").path))
    #expect(try await temp.repo.status().isClean)
  }

  @Test func pushFetchPull() async throws {
    let remote = try await TempRepo(bare: true)
    let parent = remote.root.deletingLastPathComponent()
    let first = try await TempRepo(cloning: remote.root, name: "first")
    try first.write("a.txt", "a\n")
    try await first.commitAll("init")
    // No upstream yet: push sets it.
    try await first.repo.push()
    var status = try await first.repo.status()
    #expect(status.upstream == "origin/main" && status.ahead == 0)

    let second = try await TempRepo(cloning: remote.root, name: "second")
    try second.write("b.txt", "b\n")
    try await second.commitAll("second")
    try await second.repo.push()

    try await first.repo.fetch()
    status = try await first.repo.status()
    #expect(status.behind == 1)
    try await first.repo.pull()
    #expect(try first.read("b.txt") == "b\n")
    #expect(try await first.repo.status().behind == 0)
    _ = parent
  }
}

@Suite struct DiscoveryTests {
  @Test func findsNestedRepositoriesAndSkipsIgnoredFolders() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "GitKitDiscovery-\(UUID().uuidString)")
    let fm = FileManager.default
    for path in [
      "a/.git", "group/b/.git", "group/b/nested/.git", "node_modules/c/.git", ".hidden/d/.git",
      "plain/folder", "deep/1/2/3/4/5/6/7/.git", "wt/.git",
    ] {
      try fm.createDirectory(
        at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    // A worktree has a .git file.
    try fm.removeItem(at: root.appendingPathComponent("wt/.git"))
    try "gitdir: /elsewhere".write(
      to: root.appendingPathComponent("wt/.git"), atomically: true, encoding: .utf8)

    let found = RepoDiscovery.scan(root).map { $0.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "") }
    #expect(found == ["a", "group/b", "wt"])
    #expect(RepoDiscovery.scan(root.appendingPathComponent("a")).count == 1)
    #expect(RepoDiscovery.scan(root.appendingPathComponent("plain")).isEmpty)
  }
}

@MainActor @Suite struct SessionTests {
  @Test func refreshesAndStagesThroughSession() async throws {
    let temp = try await TempRepo()
    try temp.write("a.txt", "a\n")
    try await temp.commitAll("init")
    try temp.write("a.txt", "b\n")

    let session = RepositorySession(repository: temp.repo)
    await session.refresh()
    #expect(session.status?.unstaged.count == 1)
    #expect(session.currentBranch?.name == "main")

    await session.stage(session.status?.unstaged ?? [])
    #expect(session.status?.staged.count == 1)
    #expect(await session.commit(message: "Change"))
    #expect(session.status?.isClean == true)
    await session.loadMoreCommits()
    #expect(session.commits.first?.subject == "Change")
    #expect(session.failure == nil)

    await session.push()
    #expect(session.failure != nil)  // no remote
  }
}
