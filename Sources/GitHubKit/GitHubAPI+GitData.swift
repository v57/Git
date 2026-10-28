import CryptoKit
import Foundation

/// A file in a repository's tree, from the Git Data API.
public struct GitHubTreeEntry: Sendable, Hashable, Decodable {
  public var path: String
  public var mode: String
  /// `blob` for a file, `tree` for a folder, `commit` for a submodule.
  public var type: String
  public var sha: String
  public var size: Int?
}

/// A change for `createTree`: a file's new blob, or its deletion when `sha` is `nil`.
public struct GitHubTreeChange: Sendable, Hashable {
  public var path: String
  public var sha: String?

  public init(path: String, sha: String?) {
    self.path = path
    self.sha = sha
  }
}

/// Repositories and the Git Data API (refs, commits, trees, blobs): enough to download a branch
/// and commit to it without git itself.
extension GitHubAPI {
  /// The signed-in user's repositories, most recently updated first (up to `limit`, which is
  /// rounded up to a page of 100).
  public func repositories(limit: Int = 300) async throws -> [GitHubRepository] {
    var all: [GitHubRepository] = []
    var page = 1
    while all.count < limit {
      let batch: [GitHubRepository] = try await send(
        "GET",
        "/user/repos?per_page=100&page=\(page)&sort=updated"
          + "&affiliation=owner,collaborator,organization_member")
      all += batch
      if batch.count < 100 { break }
      page += 1
    }
    return all
  }

  public func repository(owner: String, name: String) async throws -> GitHubRepository {
    try await send("GET", Self.repoPath(owner, name))
  }

  /// Whether the repository has no branches yet: nothing was ever pushed to it.
  public func isEmpty(owner: String, name: String) async throws -> Bool {
    struct Branch: Decodable { var name: String }
    let branches: [Branch] = try await send("GET", Self.repoPath(owner, name) + "/branches?per_page=1")
    return branches.isEmpty
  }

  /// Sets the repository's visibility and, unless `description` is empty, its description.
  public func updateRepository(owner: String, name: String, description: String = "", isPrivate: Bool)
    async throws -> GitHubRepository
  {
    struct Body: Encodable {
      var description: String?
      var `private`: Bool
    }
    let body = Body(description: description.isEmpty ? nil : description, private: isPrivate)
    return try await send("PATCH", Self.repoPath(owner, name), body: body)
  }

  /// The commit `branch` points at.
  public func head(owner: String, name: String, branch: String) async throws -> String {
    struct Ref: Decodable {
      struct Object: Decodable { var sha: String }
      var object: Object
    }
    let ref: Ref = try await send("GET", Self.repoPath(owner, name) + "/git/ref/heads/" + Self.refPath(branch))
    return ref.object.sha
  }

  /// The tree of `commit`.
  public func tree(owner: String, name: String, commit: String) async throws -> String {
    struct Commit: Decodable {
      struct Tree: Decodable { var sha: String }
      var tree: Tree
    }
    let result: Commit = try await send("GET", Self.repoPath(owner, name) + "/git/commits/" + commit)
    return result.tree.sha
  }

  /// Every file in `tree` and its subfolders.
  public func files(owner: String, name: String, tree: String) async throws -> [GitHubTreeEntry] {
    struct Tree: Decodable { var tree: [GitHubTreeEntry] }
    let result: Tree = try await send("GET", Self.repoPath(owner, name) + "/git/trees/\(tree)?recursive=1")
    return result.tree.filter { $0.type == "blob" }
  }

  /// A blob's bytes.
  public func blob(owner: String, name: String, sha: String) async throws -> Data {
    try await raw(
      "GET", Self.repoPath(owner, name) + "/git/blobs/" + sha, accept: "application/vnd.github.raw+json"
    ).0
  }

  /// Uploads `content` and returns its blob's sha.
  public func createBlob(owner: String, name: String, content: Data) async throws -> String {
    struct Body: Encodable {
      var content: String
      var encoding = "base64"
    }
    let created: Created = try await send(
      "POST", Self.repoPath(owner, name) + "/git/blobs", body: Body(content: content.base64EncodedString()))
    return created.sha
  }

  /// A tree that is `base` with `changes` applied, and returns its sha.
  public func createTree(owner: String, name: String, base: String, changes: [GitHubTreeChange])
    async throws -> String
  {
    struct Entry: Encodable {
      var change: GitHubTreeChange
      enum CodingKeys: String, CodingKey { case path, mode, type, sha }
      func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(change.path, forKey: .path)
        try container.encode("100644", forKey: .mode)
        try container.encode("blob", forKey: .type)
        // A null sha deletes the file.
        if let sha = change.sha { try container.encode(sha, forKey: .sha) } else { try container.encodeNil(forKey: .sha) }
      }
    }
    struct Body: Encodable {
      var base_tree: String
      var tree: [Entry]
    }
    let created: Created = try await send(
      "POST", Self.repoPath(owner, name) + "/git/trees",
      body: Body(base_tree: base, tree: changes.map { Entry(change: $0) }))
    return created.sha
  }

  /// A commit of `tree` on top of `parent`, and returns its sha.
  public func createCommit(owner: String, name: String, message: String, tree: String, parent: String)
    async throws -> String
  {
    struct Body: Encodable {
      var message: String
      var tree: String
      var parents: [String]
    }
    let created: Created = try await send(
      "POST", Self.repoPath(owner, name) + "/git/commits",
      body: Body(message: message, tree: tree, parents: [parent]))
    return created.sha
  }

  /// Moves `branch` to `commit`, only forward: GitHub answers 422 when `commit` doesn't descend
  /// from the branch's head.
  public func updateBranch(owner: String, name: String, branch: String, to commit: String) async throws {
    struct Body: Encodable {
      var sha: String
      var force = false
    }
    struct Ref: Decodable { var ref: String }
    let _: Ref = try await send(
      "PATCH", Self.repoPath(owner, name) + "/git/refs/heads/" + Self.refPath(branch), body: Body(sha: commit))
  }

  /// Git's object id for file contents: SHA-1 of "blob <size>\0<bytes>". Equal ids mean equal
  /// contents, so local edits are found without asking GitHub.
  public static func blobSHA(_ data: Data) -> String {
    var hasher = Insecure.SHA1()
    hasher.update(data: Data("blob \(data.count)\0".utf8))
    hasher.update(data: data)
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private struct Created: Decodable { var sha: String }

  private static func repoPath(_ owner: String, _ name: String) -> String {
    "/repos/\(pathComponent(owner))/\(pathComponent(name))"
  }

  /// A branch name in a URL path: its slashes stay (`feature/x`), everything else is escaped.
  private static func refPath(_ branch: String) -> String {
    branch.split(separator: "/", omittingEmptySubsequences: false).map { pathComponent(String($0)) }
      .joined(separator: "/")
  }
}
