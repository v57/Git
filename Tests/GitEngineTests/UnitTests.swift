import CryptoKit
import Foundation
import Testing

@testable import GitEngine

@Suite struct PackTests {
  /// A pack git made, indexed by the engine, gives the same `.idx` bytes as `git index-pack`.
  @Test func indexesGitPacksLikeIndexPack() throws {
    let fixture = try Fixture()
    for round in 1...8 {
      try fixture.write("file.txt", Fixture.lines(1...(200 + round * 3)))
      try fixture.write("other\(round % 3).txt", String(repeating: "x", count: round * 1000))
      try fixture.commitAll("Round \(round)")
    }
    let pack = try gitData(
      ["pack-objects", "--stdout", "--revs", "--delta-base-offset", "--depth=20"], in: fixture.root,
      input: Data("HEAD\n".utf8))
    let folder = fixture.sibling("packs")
    let indexer = try PackIndexer(packDirectory: folder, progress: nil)
    // Arrives in odd-sized pieces, as from a network.
    var offset = 0
    var size = 1
    while offset < pack.count {
      let end = min(pack.count, offset + size)
      try indexer.append(pack[offset..<end])
      offset = end
      size = size * 3 % 4093 + 1
    }
    let indexURL = try #require(try indexer.finish(store: nil))
    #expect(indexer.entries.contains { if case .offset = $0.base { true } else { false } })
    let packURL = indexURL.deletingPathExtension().appendingPathExtension("pack")
    let copy = folder.appendingPathComponent("copy.pack")
    try FileManager.default.copyItem(at: packURL, to: copy)
    try git(["index-pack", copy.path], in: folder)
    #expect(try Data(contentsOf: indexURL) == (try Data(contentsOf: folder.appendingPathComponent("copy.idx"))))

    // The engine reads every object back through its own index.
    let store = ObjectStore(directory: fixture.root.appendingPathComponent(".git/objects"))
    let index = try PackIndex(url: indexURL)
    let file = try PackFile(index: index)
    for (id, entryOffset) in index.entries() {
      _ = try file.entry(at: entryOffset)
      #expect(try store.read(id).id == id)
    }
  }

  /// A pack the engine writes is one git accepts.
  @Test func writesPacksGitAccepts() throws {
    let fixture = try Fixture()
    try fixture.write("a.txt", "a\n")
    try fixture.write("dir/b.txt", String(repeating: "b", count: 100_000))
    try fixture.commitAll("One")
    try fixture.write("a.txt", "changed\n")
    try fixture.commitAll("Two")
    let store = ObjectStore(directory: fixture.root.appendingPathComponent(".git/objects"))
    let head = try #require(ObjectID(hex: try fixture.git("rev-parse", "HEAD").trimmingCharacters(in: .newlines)))
    let first = try #require(ObjectID(hex: try fixture.git("rev-parse", "HEAD~1").trimmingCharacters(in: .newlines)))
    let everything = try PackWriter.objectsMissing(from: [], toReach: head, store: store)
    #expect(everything.count == 2 + 3 + 3)  // 2 commits, root trees + dir, 3 blobs
    let missing = try PackWriter.objectsMissing(from: [first], toReach: head, store: store)
    #expect(missing.count == 3)  // the commit, its root tree, the changed blob
    let pack = try PackWriter.pack(everything, from: store)
    let target = fixture.sibling("target")
    try git(["init", "-q", "--bare", target.path], in: fixture.parent)
    _ = try gitData(["index-pack", "--stdin", "--strict"], in: target, input: pack)
    try git(["update-ref", "refs/heads/main", head.hex], in: target)
    try git(["fsck", "--strict"], in: target)
  }

  @Test func appliesDeltas() throws {
    let base = Data("hello world, hello git".utf8)
    // Copy 0..<6 ("hello "), insert "there", copy 11..<22.
    var delta = Data([UInt8(base.count), 22])
    delta.append(contentsOf: [0x90, 6])
    delta.append(5)
    delta.append(contentsOf: Array("there".utf8))
    delta.append(contentsOf: [0x91, 11, 11])
    #expect(try Delta.apply(delta, to: base) == Data("hello there, hello git".utf8))
    #expect(throws: GitEngineError.self) { try Delta.apply(Data([3, 1, 1, 0x41]), to: base) }
    for value in [0, 1, 127, 128, 255, 16383, 16384, 1 << 31, 1 << 40] {
      let bytes = PackVarint.encodeOffset(value)
      bytes.withUnsafeBytes { #expect(PackVarint.offset($0, at: 0)?.value == value) }
      let header = PackVarint.encodeEntryHeader(type: 3, size: value)
      header.withUnsafeBytes {
        let parsed = PackVarint.entryHeader($0, at: 0)
        #expect(parsed?.type == 3 && parsed?.size == value && parsed?.length == header.count)
      }
    }
  }
}

@Suite struct ProtocolTests {
  @Test func readsPktLines() async throws {
    var data = PktLine.encode("# service=git-upload-pack\n")
    data.append(PktLine.flushPacket)
    data.append(PktLine.encode("version 2\n"))
    data.append(PktLine.encode("agent=git/2.45\n"))
    data.append(PktLine.encode("ls-refs=unborn\n"))
    data.append(PktLine.encode("fetch=shallow wait-for-done\n"))
    data.append(PktLine.flushPacket)
    let advertisement = try await Advertisement.parse(data)
    #expect(advertisement.version2)
    #expect(advertisement.supports("agent"))
    #expect(advertisement.supports("fetch", feature: "shallow"))
    #expect(!advertisement.supports("fetch", feature: "sideband-all"))

    let zero = String(repeating: "0", count: 40)
    let main = String(repeating: "a", count: 40)
    let tag = String(repeating: "b", count: 40)
    let peeled = String(repeating: "c", count: 40)
    var v0 = PktLine.encode("# service=git-upload-pack\n")
    v0.append(PktLine.flushPacket)
    let capabilities = "multi_ack side-band-64k symref=HEAD:refs/heads/main\n"
    v0.append(PktLine.encode(Array("\(main) HEAD".utf8) + [0] + Array(capabilities.utf8)))
    v0.append(PktLine.encode("\(main) refs/heads/main\n"))
    v0.append(PktLine.encode("\(tag) refs/tags/v1\n"))
    v0.append(PktLine.encode("\(peeled) refs/tags/v1^{}\n"))
    v0.append(PktLine.flushPacket)
    let old = try await Advertisement.parse(v0)
    #expect(!old.version2 && old.supports("side-band-64k"))
    #expect(old.refs.map(\.name) == ["HEAD", "refs/heads/main", "refs/tags/v1"])
    #expect(old.refs[0].symrefTarget == "refs/heads/main")
    #expect(old.refs[2].peeled == ObjectID(hex: peeled))

    var empty = PktLine.encode(Array("\(zero) capabilities^{}".utf8) + [0] + Array("report-status\n".utf8))
    empty.append(PktLine.flushPacket)
    let emptyAdvertisement = try await Advertisement.parse(empty)
    #expect(emptyAdvertisement.refs.isEmpty && emptyAdvertisement.supports("report-status"))

    var reader = PktLineReader(DataByteIterator(Data("0006a\n0000000100020004".utf8)))
    #expect(try await reader.next() == .data(Array("a\n".utf8)))
    #expect(try await reader.next() == .flush)
    #expect(try await reader.next() == .delimiter)
    #expect(try await reader.next() == .responseEnd)
    #expect(try await reader.next() == .data([]))
    #expect(try await reader.next() == nil)
    var broken = PktLineReader(DataByteIterator(Data("00zz".utf8)))
    await #expect(throws: GitEngineError.self) { try await broken.next() }
  }

  @Test func splitsSideBand() throws {
    final class Collected: @unchecked Sendable { var lines: [String] = [] }
    let collected = Collected()
    var band = SideBand { collected.lines.append($0) }
    #expect(try band.handle([1, 9, 8]) == [9, 8])
    #expect(try band.handle([2] + Array("Counting: 1\rCounting: 2\rCou".utf8)) == nil)
    #expect(try band.handle([2] + Array("nting: 3, done.\n".utf8)) == nil)
    #expect(collected.lines == ["Counting: 1", "Counting: 2", "Counting: 3, done."])
    #expect(throws: GitEngineError.self) { try band.handle([3] + Array("access denied".utf8)) }
  }

  @Test func checksPushReports() throws {
    try ReceivePack.check(["unpack ok", "ok refs/heads/main"], ref: "refs/heads/main")
    #expect(throws: GitEngineError.self) {
      try ReceivePack.check(["unpack ok", "ng refs/heads/main non-fast-forward"], ref: "refs/heads/main")
    }
    #expect(throws: GitEngineError.self) { try ReceivePack.check(["unpack index-pack failed"], ref: "refs/heads/main") }
  }

  @Test func mapsRefspecs() {
    let spec = Refspec("+refs/heads/*:refs/remotes/origin/*")!
    #expect(spec.force)
    #expect(spec.map("refs/heads/feature/x") == "refs/remotes/origin/feature/x")
    #expect(spec.map("refs/tags/v1") == nil)
    #expect(spec.reverseMap("refs/remotes/origin/main") == "refs/heads/main")
  }
}

@Suite struct ConfigAndPatternTests {
  @Test func editsConfigLikeGit() throws {
    let text = """
      [core]
      \tbare = false
      \tfilemode
      ; a comment
      [remote "origin"]
      \turl = "https://example.com/a b.git" # trailing
      \tfetch = +refs/heads/*:refs/remotes/origin/*
      [branch "Main"]
      \tremote = origin

      """
    var config = GitConfig(text: text)
    #expect(config.bool("core.filemode", default: false))
    #expect(config.value("remote.origin.url") == "https://example.com/a b.git")
    #expect(config.value("REMOTE.origin.URL") == "https://example.com/a b.git")
    #expect(config.value("branch.main.remote") == nil)
    #expect(config.value("branch.Main.remote") == "origin")
    #expect(config.subsections(of: "remote") == ["origin"])
    try config.set("branch.Main.merge", "refs/heads/Main")
    try config.set("user.name", "Name; with # chars")
    try config.set("core.bare", nil)
    try config.add("remote.origin.fetch", "+refs/tags/*:refs/tags/*")
    let fixture = try Fixture()
    let url = fixture.root.appendingPathComponent(".git/config")
    try Data(config.text.utf8).write(to: url)
    #expect(try fixture.git("config", "branch.Main.merge") == "refs/heads/Main\n")
    #expect(try fixture.git("config", "user.name") == "Name; with # chars\n")
    #expect(try fixture.git("config", "--get-all", "remote.origin.fetch").split(separator: "\n").count == 2)
    #expect(throws: GitFailure.self) { try fixture.git("config", "core.bare") }
    #expect(GitConfig(url: url).value("user.name") == "Name; with # chars")
  }

  @Test(arguments: [
    ("*.log", "a.log", false, true), ("*.log", "dir/a.log", true, false), ("a/*/c", "a/b/c", true, true),
    ("a/*/c", "a/b/x/c", true, false), ("a/**/c", "a/b/x/c", true, true), ("a/**/c", "a/c", true, true),
    ("**/c", "x/y/c", true, true), ("a/**", "a/b/c", true, true), ("[a-c]x", "bx", true, true),
    ("[!a-c]x", "bx", true, false), ("?x", "/x", true, false), ("\\*x", "*x", true, true),
    ("[[:digit:]]*", "1abc", true, true), ("a**b", "axyb", true, true), ("a**b", "ax/yb", true, false),
  ])
  func matchesWildcards(pattern: String, text: String, pathname: Bool, expected: Bool) {
    #expect(Wildmatch.matches(Array(pattern.utf8), Array(text.utf8), pathname: pathname) == expected)
  }

  @Test func cleansCommitMessages() {
    #expect(LocalRepository.cleanedMessage("  \n\nSubject  \n\n\n\nBody\t\n\n") == "Subject\n\nBody\n")
    #expect(LocalRepository.cleanedMessage("\n \n") == "")
    #expect(LocalRepository.cleanedMessage("#1 fix") == "#1 fix\n")
  }

  @Test func validatesBranchNames() {
    for name in ["main", "feature/x", "v1.2", "fix-123"] { #expect(BranchName.isValid(name)) }
    for name in ["", "-x", "a..b", "a b", "x.lock", "a/.b", "a~1", "HEAD", "a//b", "a/"] {
      #expect(!BranchName.isValid(name), "\(name)")
    }
  }
}
