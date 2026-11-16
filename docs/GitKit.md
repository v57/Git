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

## Platforms

<!-- platforms: macos ios=partial linux windows -->

- **macOS** (14 and later): everything. The watcher uses FSEvents, and `GitNetwork`'s default reads SSH host aliases
  with `ssh -G`.
- **iOS and iPadOS** (17 and later): only through a `GitTransport`. There is no git binary, so `GitRunner.run` throws
  unless the runner has a `transport`. Git's iPhone and iPad app uses one that runs the Mac's git over SSH
  (`SSHGitTransport` in the app package, on SSHKit). For repositories on the device, use [GitEngine](GitEngine.md).
- **Linux:** git runs as a `ChildProcess` from v57/SwiftUI's `SwiftUIPortability` (swift-corelibs-foundation's
  `Process`es started side by side waited on one another), and the watcher uses inotify.
- **Windows:** Git for Windows is found on the `PATH` or in its install folders, each git is a `ChildProcess` that
  inherits only its own pipes, and the watcher uses `ReadDirectoryChangesW`.
- **Android:** not yet.

On Linux and Windows the package adds v57/SwiftUI for the `os` and `SwiftUIPortability` modules.

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

## Main API

### Reading a repository

`Repository(url:runner:)` is a `Sendable` value for one working tree. Every method runs git in it and is safe to call
from any task. Heavy reads are `@concurrent`, so parsing stays off the main actor.

- `status()` (a `WorkingTreeStatus`: `branch`, `upstream`, `ahead`, `behind`, `staged`, `unstaged`, `conflicted`,
  `operation`), `summary()` (a light `RepositorySummary` for a list) and `summaryStatus()` (the status it counts),
  `activity()` (a `RepositoryActivity`: last commit, push and change).
- `log(_:skip:limit:)` with a `LogQuery` (`revision`, `allBranches`, `path`, `search` and `searchField`),
  `changedFiles(in:)`, `diff(_:ignoreWhitespace:)` with a `DiffTarget` (`.unstaged(path:untracked:)`,
  `.staged(path:originalPath:)`, `.commit(sha:parent:path:originalPath:)`), `contents(of:at:)` with a `FileRevision`
  (`.workingTree`, `.index`, `.commit(_:)`), `lineCounts(untracked:)`, `lastCommitMessage()`.
- `branches()`, `tags()`, `stashes()`, `worktrees()`, `remotes()`, `remoteURL(_:)`, `unpushedCommits(limit:)`,
  `lastFetchDate()`, `gitDirectory()`.

```swift
let page = try await repository.log(LogQuery(allBranches: true), limit: 50)
let rows = CommitGraph.layout(page)  // one GraphRow per commit, for the branch graph
if let change = status.unstaged.first,
  let diff = try await repository.diff(.unstaged(path: change.path, untracked: change.kind == .untracked))
{
  print(diff.additions, diff.deletions)
}
```

### Staging and line staging

`stage(_:)`, `stageAll()`, `unstage(_:)`, `unstageAll()`, `discard(_:)` (untracked files go to the Trash),
`discardStaged(_:)`, and line staging with `stageLines(_:of:)`, `unstageLines(_:of:)` and `discardLines(_:of:)`,
which take the `DiffLine` ids of a `FileDiff`. `ignore(_:)` adds a line to the root `.gitignore` and stops tracking
what it ignores; `Repository.ignorePatterns(for:)` gives the lines that would ignore a path (`IgnorePatterns`: the
file, its extension, its folders).

```swift
// Stage the first hunk's changed lines only.
try await repository.stageLines(Set(diff.hunks[0].changedLineIDs), of: diff)
```

### Commits and history

`commit(message:amend:)` (returns the new commit's id), `undoLastCommit()`, `revert(_:)`, `reset(to:mode:)`
(`Repository.ResetMode`: `.soft`, `.mixed`, `.hard`), `cherryPick(_:)`, `checkout(_:)`, `squash(_:message:)`,
`createTag(_:at:message:)`.

```swift
let commits = try await repository.log(limit: 3)
let squashed = try await repository.squash(commits, message: "One change")
```

### Branches and stashes

- `createBranch(_:from:checkout:)`, `switchTo(_:)`, `merge(_:)`, `deleteBranch(_:force:)`, `isValidBranchName(_:)`,
  `isValidTagName(_:)`.
- `stash(message:includeUntracked:)`, `applyStash(_:)`, `popStash(_:)`, `dropStash(_:)`.

```swift
try await repository.createBranch("feature/login")
try await repository.stash(message: "Work in progress")
```

### Conflicts

`operationInProgress()` (a `RepositoryOperation`: merge, rebase, cherry-pick, revert), `operationSource(_:)`,
`continueOperation(_:)`, `abortOperation(_:)`, `conflictedFile(_:)` (a `ConflictedFile` with its `blocks`),
`resolveConflict(_:with:)`, `resolveConflict(_:taking:)` with a `ConflictSide`, `markResolved(_:)`.

```swift
if let file = try await repository.conflictedFile("README.md"),
  let text = file.resolved(Dictionary(uniqueKeysWithValues: file.blocks.map { ($0.id, .incoming) }))
{
  try await repository.resolveConflict("README.md", with: text)
}
```

### Clone, fetch, pull and push

`Repository.clone(_:to:runner:progress:)`, `fetch(progress:)`, `pull(progress:)`, `push(force:progress:)` (`force`
is a lease: `--force-with-lease`), `pushTag(_:progress:)`, `deleteRemoteBranch(_:progress:)`, `addRemote(_:url:)`,
and `remoteOverSSH()` with `switchToHTTPS(_:)` (move a remote whose SSH login failed to its HTTPS address, as an
`HTTPSRemote`). `GitProgress.fraction(of:)` reads a `--progress` line as a share done.

```swift
let clone = try await Repository.clone(
  "https://github.com/user/notes.git", to: URL(fileURLWithPath: "/path/to/notes")
) { line in
  if let done = GitProgress.fraction(of: line) { print(Int(done * 100), "%") }
}
try await clone.push()
```

### Setup and anything else

- `Repository.initialize(at:runner:)`, `identityConfiguration()`, `Repository.setGlobalIdentity(name:email:runner:)`,
  `adding(environment:)` (a copy that passes extra environment to every git call).
- `git(_:input:allowedExitCodes:environment:timeout:progress:)` runs `git <arguments>` and returns a `GitResult`
  (`stdout`, `stderr`, `exitCode`, `output`, `errorOutput`).

```swift
let result = try await repository.git(["rev-parse", "--abbrev-ref", "HEAD"])
print(result.output)
```

### RepositorySession

`@MainActor @Observable`, for a view. `activate()` loads everything and starts a `RepositoryWatcher`; `deactivate()`
stops it. State: `status`, `branches`, `stashes`, `tags`, `remotes`, `worktrees`, `lineCounts`, `commits` with
`graph` (`logQuery` picks them, `loadMoreCommits()` pages), `headCommit`, `unpushed`, `activity` and `progress` while
an action runs, and `failure`. Actions mirror `Repository`'s (`stage(_:)`, `commit(message:amend:)`, `fetch()`,
`pull()`, `push(force:)`, `publish(to:remote:)`, `switchTo(_:)`, …), refresh afterwards and report failures in
`failure` instead of throwing; they return `Bool` or an optional where a caller needs to know it worked.
`perform(_:failureTitle:_:)` runs your own work the same way. `snapshot` and `restore(_:)` save the last state to
show at the next launch while the first refresh runs.

```swift
@MainActor
func open(_ url: URL) async -> RepositorySession {
  let session = RepositorySession(url: url)
  await session.activate()  // loads the state and starts watching the folder
  return session
}
```

### Models

`WorkingTreeStatus` and `FileChange` (with `ChangeKind` and `ChangeArea`), `RepositorySummary`, `RepositoryActivity`,
`Commit`, `CommitFile`, `RefLabel`, `Branch`, `Worktree`, `Stash`, `Tag`, `LineCounts`, `FileDiff`, `DiffHunk`,
`DiffLine`, `ConflictedFile` and `ConflictBlock`, `RepositoryOperation`. All are `Sendable` and `Hashable`;
`WorkingTreeStatus`, `FileChange`, `RepositorySummary`, `RepositoryActivity`, `Branch` and `LineCounts` are also
`Codable`.

### Helpers

- `PatchBuilder.patch(for:selecting:direction:)`: the patch behind line staging, for a subset of a diff's lines.
- `CommitGraph.layout(_:)`: lanes for a branch graph, one `GraphRow` per commit, for commits in `git log` order.
- `ConflictParser.parse(_:)`: splits a file at its conflict markers (diff3 and zdiff3 included).
- `RepositoryWatcher(paths:latency:onChange:)`: calls back after file changes settle, ignoring git's object writes
  and lock files. `onChanges:` gets the changed paths, so one watcher can serve many repositories. On iOS there is
  nothing to watch: it calls back every `latency` (at least 2 seconds) with no paths.
- `GitExecutable.customPath`, `GitExecutable.current` and `GitExecutable.version()`: which git runs. Without a custom
  path GitKit looks in Homebrew's folders, then `/usr/bin/git` (which needs the Command Line Tools); on Windows, the
  `PATH` and Git for Windows' install folders.
- `AutoFetchSchedule`: when a background fetch is due (`isDue(lastFetched:lastAttempt:now:)`).

### Running git elsewhere

`GitRunner(extraEnvironment:transport:credentialAccount:)` is how a `Repository` runs git. Give it a `GitTransport`
and git runs on another machine instead, with the working tree there: the transport runs git and reads and writes
files. `Repository.isRemote` says which. A session polls every 5 seconds (`RepositorySession.remotePollInterval`) for
such a repository, since there is nothing to watch here. At most `GitRunner.maxConcurrentProcesses` gits run at once
across the app.

```swift
let repository = Repository(
  url: URL(fileURLWithPath: "/Users/me/MyApp"), runner: GitRunner(transport: myTransport))
```

### Credentials and the security level

- `GitCredentials.set(_:for:account:)` gives the library a `GitCredential(username:password:)` (the password is the
  token) for an HTTPS host. Each `credentialAccount` has its own. When git gets the token, it gets it through
  `GIT_CONFIG_COUNT` environment entries that clear the user's helpers for that host first, so the token is never
  stored by a helper and never appears in an argument list.
- `GitNetwork.configure(_:)` installs a `GitNetwork.Configuration(engine:level:sshClientAddress:)`: a
  `GitNetworkEngine` that does network actions in the app and the `GitSecurityLevel` to follow (`useGit`,
  `inAppFirst`, `sshOnly`, `vaultKeyOnly`), read for every action. GitEngine's `GitEngineNetwork` is that engine.
  Without a configuration every network action runs `git` with the user's own setup, as `.useGit` does.
- A level refusal is thrown as `GitNetworkRefusal`. Git failures are `GitError` (arguments, exit code, git's
  message); `isSSHLoginFailure` tells a refused SSH login apart.

```swift
GitCredentials.set(GitCredential(username: "user", password: token), for: "github.com")
```

The levels, what each allows and how the fallback to `git` works are described in the
[README](../README.md#how-it-works) and, for users, in [Privacy and Security](Privacy-and-Security.md).

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

## Related

- [GitEngine](GitEngine.md): git in Swift for devices without git, with the same models, and GitKit's in-app network
  engine.
- [GitHubKit](GitHubKit.md): the GitHub sign-in whose token goes to `GitCredentials`.
- [SSHKit](https://github.com/v57/SSH/blob/main/docs/SSHKit.md): the SSH connection Git's apps build a `GitTransport`
  on.
- The user guide's [index](README.md).
