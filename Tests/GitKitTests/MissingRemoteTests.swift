import Testing

@testable import GitKit

@Suite struct MissingRemoteTests {
  @Test(arguments: [
    "github.com: ERROR: Repository not found.",
    "ERROR: Repository not found.\nfatal: Could not read from remote repository.",
    "remote: Repository not found.\nfatal: repository 'https://github.com/v57/Remote.git/' not found",
    "fatal: repository 'https://example.com/a/b.git/' not found",
    "github.com has no repository at /v57/Remote.git.",
    "remote: The project you were looking for could not be found or you don't have permission to view it.",
  ])
  func saysTheRepositoryIsMissing(message: String) {
    #expect(MissingRemote.says(message))
  }

  @Test(arguments: [
    "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.",
    "fatal: Authentication failed for 'https://github.com/v57/Remote.git/'",
    "github.com needs you to sign in to access this repository.",
    "fatal: unable to access 'https://github.com/v57/Remote.git/': Could not resolve host: github.com",
    "The server didn't accept this key.",
  ])
  func otherFailuresArentIt(message: String) {
    #expect(!MissingRemote.says(message))
  }

  @Test func readsOwnerAndName() throws {
    for url in [
      "https://github.com/v57/Remote.git", "https://github.com/v57/Remote", "git@github.com:v57/Remote.git",
      "ssh://git@github.com:22/v57/Remote.git", "https://GitHub.com/v57/Remote/",
    ] {
      let repository = try #require(HostedRepository(url: url), "\(url)")
      #expect(repository.host == "github.com")
      #expect(repository.owner == "v57")
      #expect(repository.name == "Remote")
    }
    #expect(HostedRepository(url: "/Users/me/repo.git") == nil)
    #expect(HostedRepository(url: "https://example.com/group/sub/repo.git") == nil)
    #expect(MissingRemote(name: "origin", url: "https://gitlab.com/a/b.git").gitHub == nil)
    #expect(MissingRemote(name: "origin", url: "git@github.com:a/b.git").gitHub?.displayName == "github.com/a/b")
  }
}
