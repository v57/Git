import Foundation
import Testing

@testable import GitHubKit

@Suite struct GitDataTests {
  @Test func readsABranchWithoutAToken() async throws {
    let transport = FakeTransport([
      (200, #"{"ref":"refs/heads/feature/x","object":{"sha":"c1","type":"commit"}}"#),
      (200, #"{"sha":"c1","tree":{"sha":"t1"}}"#),
      (
        200,
        #"{"sha":"t1","tree":[{"path":"a.md","mode":"100644","type":"blob","sha":"b1","size":3},"#
          + #"{"path":"docs","mode":"040000","type":"tree","sha":"t2"}],"truncated":false}"#
      ),
      (200, "hi\n"),
    ])
    let api = GitHubAPI(token: nil, transport: transport)
    let head = try await api.head(owner: "octo cat", name: "notes", branch: "feature/x")
    let tree = try await api.tree(owner: "octo cat", name: "notes", commit: head)
    let files = try await api.files(owner: "octo cat", name: "notes", tree: tree)
    let blob = try await api.blob(owner: "octo cat", name: "notes", sha: "b1")
    #expect(head == "c1" && tree == "t1")
    #expect(files.map(\.path) == ["a.md"])
    #expect(String(decoding: blob, as: UTF8.self) == "hi\n")

    let urls = transport.requests.map { $0.url?.absoluteString }
    #expect(urls[0] == "https://api.github.com/repos/octo%20cat/notes/git/ref/heads/feature/x")
    #expect(urls[2] == "https://api.github.com/repos/octo%20cat/notes/git/trees/t1?recursive=1")
    #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    #expect(transport.requests[3].value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw+json")
  }

  @Test func commitsChangesAndDeletions() async throws {
    let transport = FakeTransport([
      (201, #"{"sha":"b2"}"#), (201, #"{"sha":"t2"}"#), (201, #"{"sha":"c2"}"#),
      (200, #"{"ref":"refs/heads/main"}"#),
    ])
    let api = GitHubAPI(token: "t", transport: transport)
    let blob = try await api.createBlob(owner: "o", name: "n", content: Data("x".utf8))
    let tree = try await api.createTree(
      owner: "o", name: "n", base: "t1",
      changes: [GitHubTreeChange(path: "a.md", sha: blob), GitHubTreeChange(path: "old.md", sha: nil)])
    let commit = try await api.createCommit(owner: "o", name: "n", message: "Update", tree: tree, parent: "c1")
    try await api.updateBranch(owner: "o", name: "n", branch: "main", to: commit)

    #expect(transport.body(0).contains(#""content":"eA==""#))
    let entries = try #require(
      (try JSONSerialization.jsonObject(with: transport.requests[1].httpBody ?? Data()) as? [String: Any])?["tree"]
        as? [[String: Any]])
    #expect(entries[0]["sha"] as? String == "b2")
    #expect(entries[1]["sha"] is NSNull)
    #expect(transport.body(2).contains(#""parents":["c1"]"#))
    #expect(transport.requests[3].httpMethod == "PATCH")
    #expect(transport.body(3).contains(#""force":false"#))
  }

  @Test func listsRepositoriesPageByPage() async throws {
    let one = #"{"name":"n","full_name":"o/n","private":false,"html_url":"https://github.com/o/n","#
      + #""clone_url":"https://github.com/o/n.git","default_branch":"main","description":"Notes"}"#
    let full = "[" + Array(repeating: one, count: 100).joined(separator: ",") + "]"
    let transport = FakeTransport([(200, full), (200, "[" + one + "]")])
    let repositories = try await GitHubAPI(token: "t", transport: transport).repositories()
    #expect(repositories.count == 101)
    #expect(repositories[0].owner == "o" && repositories[0].description == "Notes")
    #expect(transport.requests.count == 2)
    #expect(transport.requests[1].url?.query?.contains("page=2") == true)
  }

  @Test func explainsTheRateLimit() async throws {
    let api = GitHubAPI(token: nil, transport: FakeTransport([(403, #"{"message":"API rate limit exceeded for 1.2.3.4."}"#)]))
    await #expect(throws: GitHubError.api(status: 403, message: "GitHub’s rate limit is reached. Sign in, or try again later.")) {
      try await api.repository(owner: "o", name: "n")
    }
  }

  @Test func blobSHAMatchesGit() {
    // `printf 'hello\n' | git hash-object --stdin`
    #expect(GitHubAPI.blobSHA(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
  }
}
