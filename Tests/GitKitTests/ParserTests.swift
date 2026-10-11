import Foundation
import Testing

@testable import GitKit

struct StatusParserTests {
  @Test func parsesBranchRenamesConflictsAndUntracked() {
    let output = [
      "# branch.oid 9ba02bd38e86bd2e81e35b42ff04f428a608e29d",
      "# branch.head main",
      "# branch.upstream origin/main",
      "# branch.ab +2 -1",
      "1 .M N... 100644 100644 100644 aaa aaa Sources/a b.swift",
      "1 A. N... 000000 100644 100644 000 bbb new.txt",
      "1 MM N... 100644 100644 100644 ccc ddd both.txt",
      "2 R. N... 100644 100644 100644 eee eee R66 g.txt", "f.txt",
      "u UU N... 100644 100644 100644 100644 a b c conflict.txt",
      "? untracked dir/file.txt",
      "",
    ].joined(separator: "\0")
    let status = StatusParser.parse(output)
    #expect(status.branch == "main")
    #expect(status.headOID == "9ba02bd38e86bd2e81e35b42ff04f428a608e29d")
    #expect(status.upstream == "origin/main")
    #expect(status.ahead == 2 && status.behind == 1)
    #expect(status.staged.map(\.path) == ["new.txt", "both.txt", "g.txt"])
    #expect(status.staged[2].kind == .renamed && status.staged[2].originalPath == "f.txt")
    #expect(status.unstaged.map(\.path) == ["Sources/a b.swift", "both.txt", "untracked dir/file.txt"])
    #expect(status.unstaged.last?.kind == .untracked)
    #expect(status.conflicted.map(\.path) == ["conflict.txt"])
    #expect(status.changeCount == 6)
  }

  @Test func parsesInitialAndDetached() {
    let initial = StatusParser.parse("# branch.oid (initial)\0# branch.head main\0")
    #expect(initial.isUnborn && initial.branch == "main")
    let detached = StatusParser.parse("# branch.oid abc\0# branch.head (detached)\0")
    #expect(detached.isDetached)
  }
}

struct LogParserTests {
  @Test func parsesCommitsWithBodiesAndRefs() {
    let sep = "\u{1F}"
    let first = [
      "aaaa", "bbbb cccc", "Ann", "ann@x", "1700000000", "Bob", "bob@x", "1700000100",
      "HEAD -> refs/heads/main, refs/remotes/origin/main, refs/remotes/origin/HEAD, tag: refs/tags/v1",
      "Merge things", "Line one\n\nLine two\n",
    ].joined(separator: sep)
    let second = [
      "bbbb", "", "Ann", "ann@x", "1690000000", "Ann", "ann@x", "1690000000", "", "Root", "",
    ].joined(separator: sep)
    let commits = LogParser.parse(first + "\0" + "\n" + second + "\0")
    #expect(commits.count == 2)
    #expect(commits[0].isMerge && commits[0].parents == ["bbbb", "cccc"])
    #expect(commits[0].body == "Line one\n\nLine two")
    #expect(commits[0].refs.map(\.name) == ["main", "origin/main", "v1"])
    #expect(commits[0].refs[0].isCurrent && commits[0].refs[0].kind == .localBranch)
    #expect(commits[0].refs[1].kind == .remoteBranch && commits[0].refs[2].kind == .tag)
    #expect(commits[1].id == "bbbb" && commits[1].parents.isEmpty && commits[1].body.isEmpty)
    #expect(commits[1].authorDate == Date(timeIntervalSince1970: 1_690_000_000))
  }

  @Test func parsesNameStatus() {
    let files = NameStatusParser.parse("M\0a.txt\0R087\0old.txt\0new.txt\0D\0gone.txt\0A\0x y.txt\0")
    #expect(files.map(\.path) == ["a.txt", "new.txt", "gone.txt", "x y.txt"])
    #expect(files[1].kind == .renamed && files[1].originalPath == "old.txt")
    #expect(files[2].kind == .deleted && files[3].kind == .added)
  }
}

struct RefParserTests {
  @Test func parsesBranchesAndTracking() {
    let output = [
      ["refs/heads/main", "aaa", "origin/main", "ahead 2, behind 1", "*", "1700000000", "Subject"],
      ["refs/heads/old", "bbb", "origin/old", "gone", " ", "1700000000", "S"],
      ["refs/remotes/origin/HEAD", "aaa", "", "", " ", "1700000000", "S"],
      ["refs/remotes/origin/feature/x", "ccc", "", "", " ", "1700000000", "S"],
    ].map { $0.joined(separator: "\0") }.joined(separator: "\n")
    let branches = RefParser.parseBranches(output)
    #expect(branches.map(\.name) == ["main", "old", "origin/feature/x"])
    #expect(branches[0].isCurrent && branches[0].ahead == 2 && branches[0].behind == 1)
    #expect(branches[1].isUpstreamGone)
    #expect(branches[2].isRemote && branches[2].remoteName == "origin")
    #expect(branches[2].localName == "feature/x")
  }

  @Test func parsesStashes() {
    let stashes = RefParser.parseStashes(
      "stash@{0}\u{1F}abc\u{1F}1700000000\u{1F}On main: wip\0stash@{1}\u{1F}def\u{1F}1700000000\u{1F}WIP on main: x\0"
    )
    #expect(stashes.map(\.index) == [0, 1])
    #expect(stashes[0].message == "On main: wip")
  }
}

struct DiffParserTests {
  @Test func parsesHunksAndLineNumbers() throws {
    let diff = """
      diff --git a/f.swift b/f.swift
      index 1111111..2222222 100644
      --- a/f.swift
      +++ b/f.swift
      @@ -1,4 +1,3 @@ struct A {
       one
      -two
      --- not a header
      +TWO
       four
      @@ -10 +10,2 @@
      -last
      +last
      +more
      \\ No newline at end of file

      """
    let file = try #require(DiffParser.parse(diff).first)
    #expect(file.path == "f.swift" && file.oldMode == "100644")
    #expect(file.hunks.count == 2)
    let first = file.hunks[0]
    #expect(first.section == "struct A {")
    #expect(first.lines.map(\.kind) == [.context, .removed, .removed, .added, .context])
    #expect(first.lines[2].text == "-- not a header")
    #expect(first.lines[3].newLine == 2 && first.lines[4].oldLine == 4 && first.lines[4].newLine == 3)
    let second = file.hunks[1]
    #expect(second.oldCount == 1 && second.newCount == 2)
    #expect(second.lines.last?.noNewlineAtEnd == true)
    #expect(file.lines.map(\.id) == Array(0..<8))
    #expect(file.additions == 3 && file.deletions == 3)
  }

  @Test func parsesNewDeletedRenamedAndBinary() {
    let text = """
      diff --git a/n w.txt b/n w.txt
      new file mode 100644
      index 0000000..9c38d10
      --- /dev/null
      +++ b/n w.txt\t
      @@ -0,0 +1,2 @@
      +new
      +file
      diff --git a/gone.txt b/gone.txt
      deleted file mode 100644
      index 9c38d10..0000000
      --- a/gone.txt
      +++ /dev/null
      @@ -1 +0,0 @@
      -bye
      diff --git a/f.txt b/g.txt
      similarity index 66%
      rename from f.txt
      rename to g.txt
      diff --git a/img.png b/img.png
      index 1..2 100644
      Binary files a/img.png and b/img.png differ
      diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"
      old mode 100644
      new mode 100755

      """
    let files = DiffParser.parse(text)
    #expect(files.count == 5)
    #expect(files[0].isNewFile && files[0].newPath == "n w.txt" && files[0].newMode == "100644")
    #expect(files[1].isDeletedFile && files[1].oldPath == "gone.txt")
    #expect(files[2].isRename && files[2].oldPath == "f.txt" && files[2].newPath == "g.txt")
    #expect(files[2].similarity == 66 && !files[2].supportsLineSelection)
    #expect(files[3].isBinary && !files[3].supportsLineSelection)
    #expect(files[4].path == "café.txt" && files[4].isModeChangeOnly)
  }

  @Test func flagsInvalidUTF8() {
    var data = Data("diff --git a/l.txt b/l.txt\n--- a/l.txt\n+++ b/l.txt\n@@ -1 +1 @@\n-caf".utf8)
    data.append(0xE9)
    data.append(contentsOf: Array("\n+cafe\n".utf8))
    let file = DiffParser.parse(data).first
    #expect(file?.hasInvalidUTF8 == true && file?.supportsLineSelection == false)
  }
}

struct PatchBuilderTests {
  let diff = DiffParser.parse(
    """
    diff --git a/f.txt b/f.txt
    --- a/f.txt
    +++ b/f.txt
    @@ -1,3 +1,3 @@
     a
    -b
    +B
     c
    @@ -10,2 +10,3 @@
     j
    +k
     l

    """
  ).first!

  @Test func forwardKeepsUnselectedRemovalsAsContext() throws {
    // Select only "+B" (id 2): "-b" becomes context.
    let patch = try #require(PatchBuilder.patch(for: diff, selecting: [2], direction: .forward))
    #expect(patch.contains("@@ -1,3 +1,4 @@\n a\n b\n+B\n c\n"))
    #expect(!patch.contains("@@ -10"))
  }

  @Test func forwardShiftsLaterHunks() throws {
    let patch = try #require(PatchBuilder.patch(for: diff, selecting: [2, 5], direction: .forward))
    #expect(patch.contains("@@ -10,2 +11,3 @@\n j\n+k\n l\n"))
  }

  @Test func reverseDropsUnselectedRemovals() throws {
    // Select only "+B" (id 2) to unstage: "-b" is dropped.
    let patch = try #require(PatchBuilder.patch(for: diff, selecting: [2], direction: .reverse))
    #expect(patch.contains("@@ -1,2 +1,3 @@\n a\n+B\n c\n"))
  }

  @Test func nothingSelectedGivesNoPatch() {
    #expect(PatchBuilder.patch(for: diff, selecting: [0, 3], direction: .forward) == nil)
  }
}
