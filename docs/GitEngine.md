# GitEngine

## Purpose

GitEngine is git written in Swift, for devices with no git binary: iPhone and iPad. It reads and writes a
repository's own files (objects, packs, the index, refs, config) and speaks git's smart HTTP and SSH protocols.
`LocalRepository` returns [GitKit](GitKit.md)'s models (`WorkingTreeStatus`, `Commit`, `Branch`, `FileDiff`, …), so
the same views work for both. `GitEngineNetwork` also does clone, fetch, pull and push for GitKit's `Repository` on
the Mac, so the app's key or token never reaches a `git` process.

It is not a full git. There is no line staging, amend, merge, rebase or stash. Pull only fast-forwards. Push sends the
current branch, never forced unless you ask with a lease. It doesn't handle `.gitattributes`, autocrlf, submodules,
shallow clones or SHA-256 repositories yet. What it can't do, it refuses with a `GitEngineError` that says why.

## Platforms

<!-- platforms: macos ios linux windows=planned -->

- **iOS and iPadOS** (17 and later): what it is for. Git's iPhone and iPad app keeps its repositories in the app's
  Documents folder, which the Files app shows.
- **macOS** (14 and later): everything. Git's Mac app uses it as GitKit's network engine.
- **Linux:** built and tested, with the system's zlib (the package adds it as a system library) and
  FoundationNetworking for smart HTTP, where a response's body arrives whole instead of streaming. Git's Linux app
  does not link it: network actions there run `git`.
- **Windows:** the package adds v57/SwiftUI's `CryptoKit` stand-in there, but not the zlib module it adds on Linux; it
  hasn't been tested there, and Git's Windows app does not link it.
- **Android:** not yet.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Git.git", branch: "main"),
],
targets: [
  .target(
    name: "MyApp",
    dependencies: [.product(name: "GitEngine", package: "Git"), .product(name: "GitKit", package: "Git")]),
]
```

GitEngine links the system's zlib (on Linux, `apt install zlib1g-dev`).

Clone, change a file, commit and push:

```swift
import Foundation
import GitEngine
import GitKit

GitCredentials.set(GitCredential(username: "user", password: token), for: "github.com")

let folder = URL.documentsDirectory.appending(path: "notes")
let repository = try await LocalRepository.clone(from: "https://github.com/user/notes.git", to: folder)
try Data("# Notes\n".utf8).write(to: folder.appending(path: "README.md"))
try await repository.stageAll()
let sha = try await repository.commit(
  message: "Update README", author: GitSignature(name: "User", email: "user@example.com"))
try await repository.push()
```

## Main API

### Opening and creating repositories

`LocalRepository(url:)` opens a working tree (it throws when `url/.git` isn't a repository). The value is cheap and
safe to share between tasks: each call opens the files afresh. Heavy calls are `@concurrent`.

- `LocalRepository.isRepository(_:)`, `LocalRepository.initialize(at:initialBranch:)` (`main` by default; not
  `async`), `LocalRepository.clone(from:to:progress:)` (HTTPS, or SSH through `GitSSH`; the folder must be missing or
  empty).
- `config(_:)` and `setConfig(_:_:)` read and write `.git/config` (`nil` removes a key).

```swift
let repository = try LocalRepository.initialize(at: folder)
try repository.setConfig("user.name", "User")
```

### Reading

`status()`, `log(revision:skip:limit:)`, `changedFiles(in:)`, `diff(_:)` with GitKit's `DiffTarget` (`nil` when the
file has no changes), `contents(of:at:)` with GitKit's `FileRevision`, `branches()`, `remotes()`, `remoteURL(_:)`,
`lastFetchDate()`.

```swift
let status = try await repository.status()
let history = try await repository.log(limit: 50)
if let change = status.unstaged.first {
  let diff = try await repository.diff(.unstaged(path: change.path, untracked: change.kind == .untracked))
}
```

### Changing

`stage(_:)`, `stageAll()`, `unstage(_:)`, `unstageAll()`, `discard(_:)` (untracked files are deleted),
`commit(message:author:)` with a `GitSignature(name:email:date:timeZone:)` (returns the new commit's id; refuses when
nothing is staged), `createBranch(_:checkout:)`, `switchTo(_:)`, `addRemote(_:url:)`.

```swift
try await repository.stage(["README.md"])
try await repository.createBranch("draft")
```

### Fetch, pull and push

`fetch(progress:)` (every remote, pruning), `pull(progress:)` (fetch, then fast-forward; refuses diverged branches),
`push(force:progress:)` (with `force`, only when the remote has nothing you haven't fetched),
`pushTag(_:to:progress:)`, `deleteRemoteBranch(_:on:expected:progress:)` (only while the branch is still at
`expected`).

```swift
try await repository.pull { line in print(line) }
try await repository.pushTag("v1.0", to: "origin")
```

### Credentials and SSH

- HTTPS reads GitKit's `GitCredentials` in-process, over `https` only. A redirect to another host or off HTTPS drops
  the `Authorization` header.
- SSH goes through a connector you install with `GitSSH.setConnector(_:)`. GitEngine speaks git's protocol, not SSH:
  the connector logs in (with your key and your host key check) and returns a `GitSSHChannel` running the command
  (`git-upload-pack` or `git-receive-pack`) for a `GitSSHAddress` (`user`, `host`, `port`, `path`). Without a
  connector, SSH remotes are refused. Git's apps install one on SSHKit that signs in with the device's key and keeps
  host keys in the vault.

```swift
GitSSH.setConnector { address, command in
  try await openChannel(to: address.host, port: address.port ?? 22, user: address.user, running: command)
}
```

`openChannel` stands for your own SSH code: anything that returns a `GitSSHChannel` (`read()`, `write(_:)`,
`finishWriting()`, `finished()`, `close()`).

### As GitKit's network engine

`GitEngineNetwork()` conforms to GitKit's `GitNetworkEngine`. Install it with `GitNetwork.configure(_:)` and GitKit's
`Repository` does its network actions through it, following the `GitSecurityLevel` the closure returns. It answers
`.done`, `.fetched` (git does the local half: a pull's merge, a clone's checkout) or `.useGit(reason:…)` when the level
lets the user's own git try instead. It falls back only for causes that say the app's way can't work (a refused key,
no token, a repository format it doesn't read), never on a server's real answer or a network failure.

```swift
GitNetwork.configure(GitNetwork.Configuration(engine: GitEngineNetwork(), level: { .inAppFirst }))
```

### Errors

`GitEngineError` has a `kind` (`.notARepository`, `.corrupt`, `.notFound`, `.refused`, `.locked`, `.authentication`,
`.network`, `.unsupported`, `.fileSystem`) and a `message` to show as it is.

```swift
do {
  try await repository.pull()
} catch let error as GitEngineError where error.kind == .refused {
  print(error.message)  // e.g. the branches have diverged
}
```

## Testing

```bash
swift test --filter GitEngineTests
```

The tests need git installed: they compare GitEngine's results with real git on temporary repositories, and serve
remotes through `git http-backend` (`Tests/GitEngineTests/GitHTTPServer.swift`), so nothing leaves the machine.
`SSHRemoteTests` run git's services through a shell instead of an sshd. `SecurityLevelTests` run every security level
with real git, and `NetworkActionTests` compare each network operation with git.

Opt-in tests that use the network:

```bash
GITENGINE_NETWORK_TESTS=1 swift test --filter GitEngineTests        # clones a small public GitHub repository
GITENGINE_CLONE_URL=https://example.com/repo.git swift test --filter clonesAnyRepository   # clones and compares with git
```

To build it for the iOS simulator from the command line:

```bash
swift build --target GitEngine --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
```

For your own tests, `GitNetwork.$scoped` (GitKit) sets a network configuration for one task, so tests can run side by
side.

## Related

- [GitKit](GitKit.md): the models GitEngine returns, `GitCredentials`, and the `Repository` it does network actions
  for.
- [SSHKit](https://github.com/v57/SSH/blob/main/docs/SSHKit.md): what Git's apps build their `GitSSH` connector on.
- The user guide's [Repositories on Other Devices](Other-Devices.md).
