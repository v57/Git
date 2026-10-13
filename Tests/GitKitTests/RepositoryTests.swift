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

  /// Another worktree of a TempRepo, sharing its runner.
  struct Worktree {
    let root: URL
    let repo: Repository
    init(url: URL) {
      root = url
      repo = Repository(url: url, runner: TempRepo.runner)
    }
    func write(_ path: String, _ text: String) throws {
      try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
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

  @Test func publishAddsTheRemoteAndTracksIt() async throws {
    let remote = try await TempRepo(bare: true)
    let temp = try await TempRepo(in: remote.root.deletingLastPathComponent())
    try temp.write("a.txt", "a\n")
    try await temp.commitAll("init")
    try await temp.repo.addRemote("origin", url: remote.root.path)
    #expect(try await temp.repo.remoteURL("origin") == remote.root.path)
    try await temp.repo.push()
    #expect(try await temp.repo.status().upstream == "origin/main")
  }

  @Test func appCredentialReplacesTheConfiguredHelpers() async throws {
    let temp = try await TempRepo()
    let saved = temp.root.deletingLastPathComponent().appendingPathComponent("credentials")
    try await temp.repo.git(["config", "credential.helper", "store --file=\(saved.path)"])
    let host = "credentials-\(UUID().uuidString.prefix(8).lowercased()).test"
    GitCredentials.set(GitCredential(username: "octo", password: "s3cret token"), for: host)
    defer { GitCredentials.set(nil, for: host) }
    let environment = GitCredentials.environment()
    func request(_ host: String, _ extra: String = "") -> Data {
      Data("protocol=https\nhost=\(host)\n\(extra)\n".utf8)
    }

    let filled = try await temp.repo.git(
      ["credential", "fill"], input: request(host), environment: environment
    ).output
    #expect(filled.contains("username=octo\n") && filled.contains("password=s3cret token\n"))

    // `approve` runs every helper's `store`: the configured one must not see the token.
    let credential = "username=octo\npassword=s3cret token\n"
    try await temp.repo.git(
      ["credential", "approve"], input: request(host, credential), environment: environment)
    #expect(!FileManager.default.fileExists(atPath: saved.path))

    // Other hosts still use the configured helper.
    try await temp.repo.git(
      ["credential", "approve"], input: request("other.test", credential), environment: environment)
    #expect(try String(contentsOf: saved, encoding: .utf8).contains("other.test"))
  }
}

@Suite struct HistoryEditingTests {
  @Test func divergenceAndWorktrees() async throws {
    let temp = try await TempRepo()
    try temp.write("a.txt", "a\n")
    try await temp.commitAll("init")
    try await temp.repo.createBranch("feature", checkout: false)
    let worktreeURL = temp.root.deletingLastPathComponent().appendingPathComponent("wt")
    try await temp.repo.git(["worktree", "add", "-q", worktreeURL.path, "feature"])
    let worktree = TempRepo.Worktree(url: worktreeURL)
    try worktree.write("b.txt", "b\n")
    try await worktree.repo.stageAll()
    try await worktree.repo.commit(message: "feature work")

    let branches = try await temp.repo.branches()
    let feature = try #require(branches.first { $0.name == "feature" })
    #expect(feature.aheadOfHead == 1 && feature.behindHead == 0)
    #expect(branches.first { $0.name == "main" }?.aheadOfHead == 0)

    let worktrees = try await temp.repo.worktrees()
    #expect(worktrees.count == 2)
    #expect(worktrees[0].isCurrent && worktrees[0].branch == "main")
    #expect(worktrees[1].branch == "feature" && !worktrees[1].isCurrent)

    // Merging the branch brings main level with it.
    try await temp.repo.merge(feature)
    #expect(try await temp.repo.branches().first { $0.name == "feature" }?.aheadOfHead == 0)
    #expect(try temp.read("b.txt") == "b\n")
  }

  /// main and feature both change line 2 of a.txt and feature deletes b.txt that main edits.
  func conflictingMerge() async throws -> TempRepo {
    let temp = try await TempRepo()
    try temp.write("a.txt", "one\ntwo\nthree\n")
    try temp.write("b.txt", "b\n")
    try await temp.commitAll("init")
    try await temp.repo.createBranch("feature")
    try temp.write("a.txt", "one\nTWO from feature\nthree\n")
    try FileManager.default.removeItem(at: temp.root.appendingPathComponent("b.txt"))
    try await temp.commitAll("feature work")
    try await temp.repo.git(["switch", "-q", "main"])
    try temp.write("a.txt", "one\ntwo from main\nthree\n")
    try temp.write("b.txt", "b changed\n")
    try await temp.commitAll("main work")
    let feature = try #require(try await temp.repo.branches().first { $0.name == "feature" })
    await #expect(throws: GitError.self) { try await temp.repo.merge(feature) }
    return temp
  }

  @Test func resolvesMergeConflictsBlockByBlock() async throws {
    let temp = try await conflictingMerge()
    let status = try await temp.repo.status()
    #expect(status.operation == .merge)
    #expect(status.conflicted.map(\.path) == ["a.txt", "b.txt"])
    #expect(status.conflicted.map(\.conflict) == [.bothModified, .deletedByThem])
    #expect(await temp.repo.operationSource(.merge) == "feature")
    let summary = try await temp.repo.summary()
    #expect(summary.operation == .merge && summary.conflictCount == 2 && summary.needsAttention)

    let file = try #require(try await temp.repo.conflictedFile("a.txt"))
    #expect(file.blocks.count == 1)
    #expect(file.blocks[0].current == "two from main\n")
    #expect(file.blocks[0].incoming == "TWO from feature\n")
    #expect(try await temp.repo.conflictedFile("b.txt") == nil)

    let text = try #require(file.resolved([0: .currentThenIncoming]))
    try await temp.repo.resolveConflict("a.txt", with: text)
    #expect(try temp.read("a.txt") == "one\ntwo from main\nTWO from feature\nthree\n")
    // The incoming side deleted b.txt, so taking it deletes the file.
    try await temp.repo.resolveConflict("b.txt", taking: .incoming)
    #expect(!FileManager.default.fileExists(atPath: temp.root.appendingPathComponent("b.txt").path))

    let resolved = try await temp.repo.status()
    #expect(resolved.conflicted.isEmpty)
    try await temp.repo.continueOperation(.merge)
    #expect(try await temp.repo.status().operation == nil)
    #expect(try await temp.repo.log().first?.parents.count == 2)
  }

  @Test func resolvesByTakingTheCurrentSideAndAborts() async throws {
    let temp = try await conflictingMerge()
    try await temp.repo.resolveConflict("a.txt", taking: .current)
    try await temp.repo.resolveConflict("b.txt", taking: .current)
    #expect(try temp.read("a.txt") == "one\ntwo from main\nthree\n")
    #expect(try temp.read("b.txt") == "b changed\n")
    #expect(try await temp.repo.status().conflicted.isEmpty)
    try await temp.repo.abortOperation(.merge)
    #expect(try await temp.repo.status().operation == nil)
  }

  @Test func logsAllBranchesForTheGraph() async throws {
    let temp = try await TempRepo()
    try temp.write("a.txt", "a\n")
    try await temp.commitAll("init")
    try await temp.repo.createBranch("feature")
    try temp.write("b.txt", "b\n")
    try await temp.commitAll("on feature")
    try await temp.repo.git(["switch", "-q", "main"])
    #expect(try await temp.repo.log().count == 1)
    let all = try await temp.repo.log(LogQuery(allBranches: true))
    #expect(all.map(\.subject) == ["on feature", "init"])
    #expect(CommitGraph.layout(all).map(\.column) == [0, 0])
  }

  @Test func countsLinesTagsChecksOutAndCherryPicks() async throws {
    let temp = try await TempRepo()
    try temp.write("a.txt", "one\ntwo\n")
    try await temp.commitAll("init")
    try await temp.repo.createTag("v1", message: "First")
    try await temp.repo.createBranch("feature")
    try temp.write("b.txt", "b\n")
    try await temp.commitAll("add b")
    try await temp.repo.git(["switch", "-q", "main"])

    try temp.write("a.txt", "one\nTWO\nthree\n")
    try temp.write("new.txt", "x\ny")
    try await temp.repo.stage(["a.txt"])
    try temp.write("a.txt", "one\nTWO\nthree\nfour\n")
    let counts = try await temp.repo.lineCounts(untracked: ["new.txt"])
    #expect(counts.staged["a.txt"] == LineCounts(added: 2, removed: 1))
    #expect(counts.unstaged["a.txt"] == LineCounts(added: 1, removed: 0))
    #expect(counts.unstaged["new.txt"] == LineCounts(added: 2, removed: 0))
    try await temp.repo.commit(message: "edit a")
    try await temp.repo.discard([FileChange(path: "a.txt", kind: .modified, area: .unstaged)])
    try FileManager.default.removeItem(at: temp.root.appendingPathComponent("new.txt"))

    let tags = try await temp.repo.tags()
    #expect(tags.map(\.name) == ["v1"])
    let initial = try #require(try await temp.repo.log().last)
    #expect(tags.first?.commit == initial.id)

    let head = try #require(try await temp.repo.log().first)
    let files = try await temp.repo.changedFiles(in: head)
    #expect(files.first?.lines == LineCounts(added: 2, removed: 1))

    let feature = try #require(try await temp.repo.log(LogQuery(revision: "feature")).first)
    try await temp.repo.cherryPick(feature)
    #expect(try temp.read("b.txt") == "b\n")
    #expect(try await temp.repo.log().first?.subject == "add b")

    try await temp.repo.checkout(initial)
    #expect(try await temp.repo.status().isDetached)
  }

  @Test func searchesMessageAuthorAndShaAtOnce() async throws {
    let temp = try await TempRepo()
    try temp.write("a.txt", "a\n")
    try await temp.commitAll("Fix the parser")
    try temp.write("a.txt", "b\n")
    try await temp.commitAll("Unrelated")
    let byMessage = try await temp.repo.log(LogQuery(search: "parser", searchField: .any))
    #expect(byMessage.map(\.subject) == ["Fix the parser"])
    // Every commit's author is "Test".
    #expect(try await temp.repo.log(LogQuery(search: "test", searchField: .any)).count == 2)
    let sha = try #require(try await temp.repo.log().last?.id)
    let bySha = try await temp.repo.log(LogQuery(search: String(sha.prefix(7)), searchField: .any))
    #expect(bySha.map(\.id).contains(sha))
  }

  @Test func revertUndoResetAndTag() async throws {
    let temp = try await TempRepo()
    try temp.write("a.txt", "one\n")
    try await temp.commitAll("first")
    try temp.write("a.txt", "two\n")
    try await temp.commitAll("second")
    #expect(try await temp.repo.unpushedCommits().count == 2)

    let second = try #require(try await temp.repo.log().first)
    try await temp.repo.revert(second)
    #expect(try temp.read("a.txt") == "one\n")
    #expect(try await temp.repo.log().first?.subject == "Revert \"second\"")

    let message = try await temp.repo.undoLastCommit()
    #expect(message.hasPrefix("Revert \"second\""))
    #expect(try await temp.repo.status().staged.map(\.path) == ["a.txt"])
    try await temp.repo.unstageAll()

    try await temp.repo.createTag("v1", message: "Release")
    #expect(try await temp.repo.log().first?.refs.contains { $0.name == "v1" && $0.kind == .tag } == true)

    let first = try #require(try await temp.repo.log().last)
    try await temp.repo.reset(to: first.id)
    #expect(try await temp.repo.log().count == 1)
    #expect(try temp.read("a.txt") == "one\n")  // mixed reset keeps the working tree

    // Undoing the only commit leaves an unborn branch with the files staged.
    try await temp.repo.git(["checkout", "-q", "--", "."])
    try await temp.repo.undoLastCommit()
    let status = try await temp.repo.status()
    #expect(status.isUnborn && status.staged.map(\.path) == ["a.txt"])
  }

  @Test func ignoresWhitespace() async throws {
    let temp = try await TempRepo()
    try temp.write("a.txt", "a\nb\n")
    try await temp.commitAll("init")
    try temp.write("a.txt", "a  \nB\n")
    let full = try #require(try await temp.repo.diff(.unstaged(path: "a.txt", untracked: false)))
    let trimmed = try #require(
      try await temp.repo.diff(.unstaged(path: "a.txt", untracked: false), ignoreWhitespace: true))
    #expect(full.deletions == 2 && trimmed.deletions == 1)
    #expect(full.supportsLineSelection && !trimmed.supportsLineSelection)
  }
}

@Suite struct SquashTests {
  /// init, then one commit per name, each adding `<name>.txt`.
  func linearRepo(_ names: [String]) async throws -> TempRepo {
    let temp = try await TempRepo()
    try temp.write("init.txt", "init\n")
    try await temp.commitAll("init")
    for name in names {
      try temp.write("\(name).txt", "\(name)\n")
      try await temp.commitAll(name)
    }
    return temp
  }

  func tree(_ temp: TempRepo, _ revision: String = "HEAD") async throws -> String {
    try await temp.repo.git(["rev-parse", "\(revision)^{tree}"]).output
  }

  @Test func ordersARunNewestFirstAndRejectsGaps() async throws {
    let temp = try await linearRepo(["a", "b", "c"])
    let log = try await temp.repo.log()  // c, b, a, init
    #expect(try Commit.squashRun([log[2], log[0], log[1]]).map(\.subject) == ["c", "b", "a"])
    #expect(throws: GitError.self) { try Commit.squashRun([log[0], log[2]]) }
    #expect(throws: GitError.self) { try Commit.squashRun([log[0]]) }
  }

  @Test func squashesTheLatestCommitsAndKeepsStagedChanges() async throws {
    let temp = try await linearRepo(["a", "b", "c"])
    try temp.write("init.txt", "staged\n")
    try await temp.repo.stage(["init.txt"])
    try temp.write("loose.txt", "untracked\n")
    let before = try await tree(temp)
    let log = try await temp.repo.log()

    let squashed = try await temp.repo.squash([log[0], log[1]], message: "b and c\n\nBoth.  \n\n")
    let after = try await temp.repo.log()
    #expect(after.map(\.subject) == ["b and c", "a", "init"])
    #expect(after[0].id == squashed && after[0].body == "Both.")
    #expect(after[0].parents == [log[2].id])
    #expect(try await tree(temp) == before)
    let status = try await temp.repo.status()
    #expect(status.staged.map(\.path) == ["init.txt"])
    #expect(status.unstaged.map(\.path) == ["loose.txt"])
  }

  @Test func recreatesLaterCommitsAndMergesOnTop() async throws {
    let temp = try await linearRepo(["a", "b"])
    try await temp.repo.createBranch("side", checkout: false)
    try temp.write("c.txt", "c\n")
    try await temp.commitAll("c")
    try await temp.repo.git(["switch", "-q", "side"])
    try temp.write("side.txt", "side\n")
    try await temp.commitAll("on side")
    try await temp.repo.git(["switch", "-q", "main"])
    try await temp.repo.git(["merge", "-q", "--no-ff", "-m", "merge side", "side"])
    let before = try await tree(temp)
    let log = try await temp.repo.log()
    let commit = { (subject: String) in try #require(log.first { $0.subject == subject }) }
    let (a, b, c) = (try commit("a"), try commit("b"), try commit("c"))
    // "side" starts at b, so squashing b into c would bring b back through the merge.
    await #expect(throws: GitError.self) { try await temp.repo.squash([b, c], message: "b+c") }

    // Squashing a and b recreates both sides of the merge on the new commit.
    let squashed = try await temp.repo.squash([a, b], message: "a+b")
    let after = try await temp.repo.log()
    #expect(try await tree(temp) == before)
    #expect(after.count == 5 && !after.contains { $0.subject == "a" || $0.subject == "b" })
    let byID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
    let merge = after[0]
    #expect(merge.subject == "merge side" && merge.parents.count == 2)
    let first = try #require(byID[merge.parents[0]])
    let second = try #require(byID[merge.parents[1]])
    #expect(first.subject == "c" && first.parents == [squashed] && first.id != c.id)
    #expect(second.subject == "on side" && second.parents == [squashed])
    #expect(byID[squashed]?.parents == [try commit("init").id])
  }

  @Test func refusesCommitsOffTheCurrentBranch() async throws {
    let temp = try await linearRepo(["a"])
    try await temp.repo.createBranch("feature")
    try temp.write("f1.txt", "1\n")
    try await temp.commitAll("f1")
    try temp.write("f2.txt", "2\n")
    try await temp.commitAll("f2")
    let feature = try await temp.repo.log()
    try await temp.repo.git(["switch", "-q", "main"])
    await #expect(throws: GitError.self) {
      try await temp.repo.squash([feature[0], feature[1]], message: "f")
    }
    #expect(try await temp.repo.log(LogQuery(revision: "feature")).count == 4)
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

@Suite struct GroupingTests {
  @Test func groupsSiblingsByTheirOwnFolder() {
    let urls = [
      "/Users/me/Developer/Hub/Apps/hub-app", "/Users/me/Developer/Hub/Apps/hub-web",
      "/Users/me/Developer/playgra/Vijo/a", "/Users/me/Developer/playgra/Vijo/b",
      "/Users/me/Developer/playgra/Vijo/c",
      // Nested deeper: its own folder's group, not Vijo's.
      "/Users/me/Developer/playgra/Vijo/tools/x", "/Users/me/Developer/playgra/Vijo/tools/y",
      // Alone in its folder.
      "/Users/me/Developer/Hub/Server",
    ].map { URL(fileURLWithPath: $0) }
    let (groups, ungrouped) = RepoGrouping.groups(for: urls)
    #expect(groups.map(\.name) == ["Apps", "tools", "Vijo"])
    #expect(groups.map(\.note) == ["Hub", "Vijo", "playgra"])
    #expect(groups[2].repositories.map(\.lastPathComponent) == ["a", "b", "c"])
    #expect(ungrouped.map(\.lastPathComponent) == ["Server"])
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

  @Test func squashesSelectedCommitsThroughSession() async throws {
    let temp = try await TempRepo()
    for name in ["init", "a", "b", "c"] {
      try temp.write("\(name).txt", "\(name)\n")
      try await temp.commitAll(name)
    }
    let session = RepositorySession(repository: temp.repo)
    await session.refresh()
    let ids = session.commits.map(\.id)  // c, b, a, init
    #expect(throws: GitError.self) { try session.squashRun([ids[0], ids[2]]) }
    let run = try session.squashRun([ids[1], ids[0]])
    #expect(run.map(\.subject) == ["c", "b"])

    let squashed = try #require(await session.squash(run, message: "b and c"))
    #expect(session.failure == nil)
    #expect(session.commits.map(\.subject) == ["b and c", "a", "init"])
    #expect(session.commits.first?.id == squashed)
  }
}
