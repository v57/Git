# GitKit

## Purpose

GitKit runs the `git` command and turns its output into Swift models. It covers what a Git client needs: status,
diffs, staging whole files, hunks or single lines, commits, history with a branch graph, branches, tags, stashes,
conflicts, and clone, fetch, pull and push. `RepositorySession` keeps one repository's state current for a SwiftUI
view. GitKit never parses human-readable output: it reads porcelain v2, `-z` separated records and `%x1f` separated
log fields.

GitKit is not a git implementation. It needs a `git` binary on the machine where the repository is, or a
`GitTransport` that runs git somewhere else (another machine over SSH). For repositories on a device with no git, use
[GitEngine](GitEngine.md), which speaks the same models. GitKit has no UI.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Git.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "GitKit", package: "Git")]),
]
```

The package also builds GitHubKit and GitHubUI, which pull in Vault and Component from GitHub. With `V57_LOCAL=1` in
the environment, SwiftPM takes them from checkouts next to this one instead.

Read the status, stage everything and commit:

```swift
import Foundation
import GitKit

let repository = Repository(url: URL(fileURLWithPath: "/path/to/MyApp"))
let status = try await repository.status()
for change in status.unstaged {
  print(change.kind, change.path)
}
try await repository.stageAll()
let sha = try await repository.commit(message: "Update the readme")
let recent = try await repository.log(LogQuery(), limit: 20)
```

For a view, use the observable session. Its actions refresh afterwards and report failures in `failure` instead of
throwing:

```swift
@MainActor
func open(_ url: URL) async -> RepositorySession {
  let session = RepositorySession(url: url)
  await session.activate()  // loads the state and starts watching the folder
  return session
}
```

## Main API

### Repository

`Repository(url:runner:)` is a `Sendable` value for one working tree. Every method runs git in it and is safe to call
from any task. Heavy reads are `@concurrent`, so parsing stays off the main actor.

- Reading: `status()`, `summary()` (a light `RepositorySummary` for a list), `log(_:skip:limit:)` with a `LogQuery`
  (revision, all branches, path, search), `changedFiles(in:)`, `diff(_:ignoreWhitespace:)` with a `DiffTarget`
  (`.unstaged`, `.staged`, `.commit`), `contents(of:at:)` with a `FileRevision`, `lineCounts(untracked:)`,
  `branches()`, `tags()`, `stashes()`, `worktrees()`, `remotes()`, `remoteURL(_:)`, `unpushedCommits(limit:)`,
  `lastFetchDate()`.
- Staging: `stage(_:)`, `stageAll()`, `unstage(_:)`, `unstageAll()`, `discard(_:)` (untracked files go to the Trash),
  `discardStaged(_:)`, and line staging with `stageLines(_:of:)`, `unstageLines(_:of:)` and `discardLines(_:of:)`,
  which take line indexes of a `FileDiff`.
- Commits: `commit(message:amend:)`, `lastCommitMessage()`, `undoLastCommit()`, `revert(_:)`,
  `reset(to:mode:)`, `cherryPick(_:)`, `checkout(_:)`, `squash(_:message:)`, `createTag(_:at:message:)`.
- Branches: `createBranch(_:from:checkout:)`, `switchTo(_:)`, `merge(_:)`, `deleteBranch(_:force:)`,
  `isValidBranchName(_:)`, `isValidTagName(_:)`.
- Stashes: `stash(message:includeUntracked:)`, `applyStash(_:)`, `popStash(_:)`, `dropStash(_:)`.
- Conflicts and operations: `operationInProgress()` (merge, rebase, cherry-pick, revert), `continueOperation(_:)`,
  `abortOperation(_:)`, `conflictedFile(_:)`, `resolveConflict(_:with:)`, `resolveConflict(_:taking:)`,
  `markResolved(_:)`.
- Network: `Repository.clone(_:to:runner:progress:)`, `fetch(progress:)`, `pull(progress:)`,
  `push(force:progress:)`, `pushTag(_:progress:)`, `deleteRemoteBranch(_:progress:)`, `addRemote(_:url:)`,
  `remoteOverSSH()` and `switchToHTTPS(_:)` (move a remote whose SSH login failed to its HTTPS address).
- Setup: `Repository.initialize(at:runner:)`, `identityConfiguration()`, `Repository.setGlobalIdentity(name:email:runner:)`,
  `adding(environment:)` (a copy that passes extra environment to every git call), `ignore(_:)` and
  `Repository.ignorePatterns(for:)`.
- Anything else: `git(_:input:allowedExitCodes:environment:timeout:progress:)` runs `git <arguments>` and returns a
  `GitResult` (`stdout`, `stderr`, `exitCode`, `output`).

### RepositorySession

`@MainActor @Observable`. `activate()` loads everything and starts a `RepositoryWatcher`; `deactivate()` stops it.
State: `status`, `branches`, `stashes`, `tags`, `remotes`, `worktrees`, `lineCounts`, `commits` with `graph`,
`headCommit`, `unpushed`, `activity` and `progress` while an action runs, and `failure`. Actions mirror
`Repository`'s (`stage`, `commit(message:amend:)`, `fetch()`, `pull()`, `push(force:)`, `switchTo(_:)`, …) and
return `Bool` or an optional where a caller needs to know it worked. `snapshot` and `restore(_:)` save the last state
to show at the next launch while the first refresh runs.

### Models

`WorkingTreeStatus` and `FileChange` (with `ChangeKind` and `ChangeArea`), `RepositorySummary`, `Commit`,
`CommitFile`, `RefLabel`, `Branch`, `Worktree`, `Stash`, `Tag`, `LineCounts`, `FileDiff`, `DiffHunk`, `DiffLine`,
`ConflictedFile` and `ConflictBlock`, `RepositoryOperation`. All are `Sendable` and `Hashable`; most are `Codable`.

### Helpers

- `PatchBuilder.patch(for:selecting:direction:)`: the patch behind line staging, for a subset of a diff's lines.
- `CommitGraph.layout(_:)`: lanes for a branch graph, one `GraphRow` per commit, for commits in `git log` order.
- `ConflictParser.parse(_:)`: splits a file at its conflict markers (diff3 and zdiff3 included).
- `RepositoryWatcher(paths:latency:onChange:)`: calls back after file changes settle, ignoring git's object writes
  and lock files. `onChanges:` gets the changed paths, so one watcher can serve many repositories.
- `GitExecutable.customPath` and `GitExecutable.current`: which git runs. Without a custom path GitKit looks in
  Homebrew's folders, then `/usr/bin/git` (which needs the Command Line Tools).
- `AutoFetchSchedule`: when a background fetch is due.

### Running git elsewhere

`GitRunner(extraEnvironment:transport:credentialAccount:)` is how a `Repository` runs git. Give it a `GitTransport`
and git runs on another machine instead, with the working tree there: the transport runs git and reads and writes
files. `Repository.isRemote` says which. A session polls every 5 seconds for such a repository, since there is
nothing to watch here. At most `GitRunner.maxConcurrentProcesses` gits run at once across the app.

### Credentials and the security level

- `GitCredentials.set(_:for:account:)` gives the library a `GitCredential` (user name and token) for an HTTPS host.
  Each `credentialAccount` has its own. When git gets the token, it gets it through `GIT_CONFIG_COUNT` environment
  entries that clear the user's helpers for that host first, so the token is never stored by a helper and never
  appears in an argument list.
- `GitNetwork.configure(_:)` installs a `GitNetwork.Configuration`: the `GitSecurityLevel` to follow and a
  `GitNetworkEngine` that does network actions in the app. GitEngine's `GitEngineNetwork` is that engine. Without a
  configuration every network action runs `git` with the user's own setup, as `GitSecurityLevel.useGit` does.
- A level refusal is thrown as `GitNetworkRefusal`. Git failures are `GitError` (arguments, exit code, git's
  message); `isSSHLoginFailure` tells a refused SSH login apart.

The levels, what each allows and how the fallback to `git` works are described in the
[README](../README.md#how-it-works) and, for users, in [Privacy and Security](Privacy-and-Security.md).

## Platform notes

- **macOS** (14 and later): everything. The watcher uses FSEvents.
- **iOS and iPadOS** (17 and later): builds. There is no git binary, so `GitRunner.run` throws unless the runner has
  a `transport`. Git's iPhone and iPad app uses one that runs the Mac's git over SSH (`SSHGitTransport` in the app
  package, on SSHKit). For repositories on the device, use [GitEngine](GitEngine.md).
- **Linux:** built and tested. git runs through v57/SwiftUI's `SwiftUIPortability` (Foundation's `Process` hangs when
  several gits run side by side), and the watcher uses inotify.
- **Windows:** runs. Git for Windows is found on the `PATH` or in its install folders, each git is a child process that
  inherits only its own pipes, and the watcher uses `ReadDirectoryChangesW`.
- **Android:** not yet.

On Linux and Windows the package adds v57/SwiftUI for the `os` and `SwiftUIPortability` modules.

## Testing

```bash
swift test --filter GitKitTests
```

The tests run real git on temporary repositories (`TempRepo` in `Tests/GitKitTests/RepositoryTests.swift`), isolated
from your setup with `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`. Add a test there for any new git
operation. `ParserTests` cover the parsers on fixed output, `TransportTests` a `GitTransport`, and
`RunnerStressTests` many gits at once.

For your own tests:
- `GitNetwork.$scoped` sets a network configuration for one task and what it starts, so tests can run side by side.
- `RepositorySession.Snapshot` and `restore(_:)` fill a session without git, for previews.

See also: [GitEngine](GitEngine.md), [GitHubKit](GitHubKit.md), and the user guide's [index](README.md).
