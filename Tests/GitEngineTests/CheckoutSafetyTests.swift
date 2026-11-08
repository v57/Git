import Foundation
import Testing

@testable import GitEngine

/// A tree from a hostile server can't make a clone, pull or branch switch write outside the working tree or into
/// `.git` (security audit H3). The trees are hand-made (`hash-object --literally`), served by `git http-backend`.
@Suite struct CheckoutSafetyTests {
  /// One hand-made entry: a blob's text, a symlink's target or a subtree.
  enum Node {
    case file(String)
    case link(String)
    case tree([String: Node])
  }

  /// Writes `entries` as a tree object with git, checking nothing (git's own `mktree` would refuse these names).
  static func writeTree(_ entries: [String: Node], in fixture: Fixture) throws -> ObjectID {
    var objects: [TreeEntry] = []
    for (name, node) in entries {
      switch node {
      case .file(let text):
        let id = try fixture.blob(text)
        objects.append(TreeEntry(name: name, mode: .regular, id: id))
      case .link(let target):
        objects.append(TreeEntry(name: name, mode: .symlink, id: try fixture.blob(target)))
      case .tree(let children):
        objects.append(TreeEntry(name: name, mode: .tree, id: try writeTree(children, in: fixture)))
      }
    }
    let hex = try gitData(
      ["hash-object", "-t", "tree", "-w", "--literally", "--stdin"], in: fixture.root,
      input: TreeObject.encode(objects))
    return try #require(ObjectID(hex: String(decoding: hex, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  /// A served repository whose `main` holds `entries` (plus a README), the URL to clone, and the folder the test
  /// checks stays untouched.
  struct Hostile {
    let fixture: Fixture
    let server: GitHTTPServer
    let url: String

    init(_ entries: [String: Node]) throws {
      fixture = try Fixture()
      try fixture.write("README.md", "Hello\n")
      try fixture.commitAll("Initial commit")
      var all = entries
      all["README.md"] = .file("Hello\n")
      let tree = try CheckoutSafetyTests.writeTree(all, in: fixture)
      let commit = try fixture.git("commit-tree", tree.hex, "-p", "HEAD", "-m", "Hostile")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      try fixture.git("update-ref", "refs/heads/hostile", commit)
      let served = fixture.sibling("served")
      try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
      let bare = served.appendingPathComponent("repo.git")
      try git(["clone", "-q", "--bare", "--no-local", fixture.root.path, bare.path], in: served)
      try git(["symbolic-ref", "HEAD", "refs/heads/hostile"], in: bare)
      server = try GitHTTPServer(root: served)
      url = "\(server.baseURL)/repo.git"
    }

    /// Clones the hostile branch; returns the error the clone threw, if any.
    func clone() async -> (any Error)? {
      do {
        _ = try await LocalRepository.clone(from: url, to: fixture.sibling("clone"))
        return nil
      } catch {
        return error
      }
    }

    func outside(_ path: String) -> Bool {
      FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(path).path)
    }
  }

  @Test func checkoutRefusesDotDotEntry() async throws {
    let hostile = try Hostile(["..": .tree(["planted.txt": .file("pwned\n")])])
    defer { hostile.server.stop() }
    #expect(await hostile.clone() != nil)
    #expect(!hostile.outside("planted.txt"))
  }

  @Test func checkoutRefusesDotGitEntry() async throws {
    for name in [".git", ".GIT", ".Git\u{200C}", ".git.", "git~1"] {
      let hostile = try Hostile([name: .tree(["config": .file("[core]\n\tfsmonitor = touch /tmp/pwned\n")])])
      defer { hostile.server.stop() }
      #expect(await hostile.clone() != nil, "\(name)")
      let config = hostile.fixture.sibling("clone/.git/config")
      let text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
      #expect(!text.contains("fsmonitor"), "\(name)")
    }
  }

  @Test func checkoutRefusesSlashInName() async throws {
    let hostile = try Hostile(["../planted.txt": .file("pwned\n")])
    defer { hostile.server.stop() }
    #expect(await hostile.clone() != nil)
    #expect(!hostile.outside("planted.txt"))
  }

  @Test func checkoutRefusesWriteThroughSymlink() async throws {
    // `Link` points out of the clone; on a case-insensitive disk `link/planted.txt` would go through it.
    let hostile = try Hostile(["Link": .link("../outside"), "link": .tree(["planted.txt": .file("pwned\n")])])
    defer { hostile.server.stop() }
    try FileManager.default.createDirectory(
      at: hostile.fixture.sibling("outside"), withIntermediateDirectories: true)
    _ = await hostile.clone()
    #expect(!hostile.outside("outside/planted.txt"))
  }

  @Test func refusesGitModulesSymlink() throws {
    #expect(!TreeObject.isSafeName(".gitmodules", mode: .symlink))
    #expect(!TreeObject.isSafeName(".GitModules ", mode: .symlink))
    #expect(TreeObject.isSafeName(".gitmodules", mode: .regular))
  }

  @Test func namesGitChecksOutStayAllowed() throws {
    for name in ["README.md", ".gitignore", ".github", "git", ".gitattributes", "a..b", "..config", "git~2"] {
      #expect(TreeObject.isSafeName(name, mode: .regular), "\(name)")
    }
    for name in ["", ".", "..", "a/b", ".git", ".GIT", ".git::$INDEX_ALLOCATION", "GIT~1", ".g\u{200D}it"] {
      #expect(!TreeObject.isSafeName(name, mode: .regular), "\(name)")
    }
  }

  /// A local branch whose tree is hostile (fetched earlier, say) can't be switched to.
  @Test func branchSwitchRefusesDotDotEntry() async throws {
    let fixture = try Fixture()
    try fixture.write("README.md", "Hello\n")
    try fixture.commitAll("Initial commit")
    let tree = try Self.writeTree(
      ["README.md": .file("Hello\n"), "..": .tree(["planted.txt": .file("pwned\n")])], in: fixture)
    let commit = try fixture.git("commit-tree", tree.hex, "-p", "HEAD", "-m", "Hostile")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try fixture.git("update-ref", "refs/heads/hostile", commit)
    let repository = try fixture.engine
    let branch = try #require(try await repository.branches().first { $0.name == "hostile" })
    await #expect(throws: (any Error).self) { try await repository.switchTo(branch) }
    #expect(!FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent("planted.txt").path))
  }
}

extension Fixture {
  /// Writes a blob with git and returns its id.
  func blob(_ text: String) throws -> ObjectID {
    let hex = try gitData(["hash-object", "-w", "--stdin"], in: root, input: Data(text.utf8))
    return ObjectID(hex: String(decoding: hex, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))!
  }
}
