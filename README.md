# Git

A Git client for macOS: a library (`GitKit`) that does everything git-related and a small SwiftUI app (`Git`)
on top of it.

The app shows commit history, colored diffs, and the working tree's staged and unstaged files. You can stage,
unstage or discard whole files, hunks or individual lines, write commits (with amend), fetch, pull and push,
switch and create branches, and stash. Drop a folder on the sidebar and every Git repository inside it is added.

## Layout

    Package.swift                 GitKit library + GitKitTests (swift-testing)
    Sources/GitKit/
      Process/    GitRunner (argv-based process runner), GitExecutable (finds git), GitError
      Models/     WorkingTreeStatus/FileChange, Commit/RefLabel, Branch/Stash, FileDiff/DiffHunk/DiffLine
      Parsing/    status --porcelain=v2, log, name-status, for-each-ref, stash list, unified diff
      Staging/    PatchBuilder: patches for a subset of a diff's lines
      Discovery/  RepoDiscovery: finds repositories inside a folder
      Session/    RepositorySession (@Observable state + actions), RepositoryWatcher (FSEvents)
      Repository.swift   every git operation, as async methods on a Sendable struct
    Git.xcodeproj                 the app; local packages ../Git (GitKit) and ../Markdown (Md)
    Git/                          app sources
      Library/    SavedRepository (SwiftData), RepositoryLibrary (sessions, summaries, import)
      Sidebar/    repositories grouped by import folder; drop or Add Folder (⇧⌘O)
      Changes/    file list, commit composer, diff with hunk/line actions
      History/    paged history with search, commit detail
      Diff/       DiffView (selection, copy), DiffHighlighter (the only file importing Md), LoadedDiff
      Toolbar/    branch menu, fetch/pull/push, stash

## How it works

- **git CLI.** GitKit runs the installed git binary with an argument vector. It looks for a custom path from
  Settings first, then Homebrew, then `/usr/bin/git` (which requires the Command Line Tools). It never parses
  human-readable output. It reads porcelain v2, `-z` separated records and `%x1f` separated log fields.
- **Your git setup applies.** Your config, hooks, commit signing, SSH agent and credential helpers all apply. The
  runner turns off terminal prompts, so a missing credential fails with git's own message instead of hanging.
- **Line staging.** `PatchBuilder` rewrites the diff and the result goes through `git apply --cached`
  (`--reverse` to unstage, no `--cached` to discard).
  - Unselected lines on the side being kept become context, and unselected lines on the other side are dropped.
  - Inside a block of changes, that context is placed so the surrounding lines keep their order.
  - New and deleted files become ordinary modifications when only part of them is applied.
- **Discarding is recoverable for new files.** Untracked files are moved to the Trash rather than deleted.
- **Live updates.** `RepositorySession` watches the working tree and `.git` with FSEvents. It ignores objects,
  logs and lock files, and refreshes status, branches, stashes and, when refs move, history.
- **Not sandboxed.** The app is distributed with Developer ID and the hardened runtime, because it runs git and
  your hooks on arbitrary folders.

## Usage

```bash
swift build && swift test
xcodebuild -project Git.xcodeproj -scheme Git -destination 'platform=macOS' build
```

Debug builds accept these launch arguments for scripted screenshots:
- `--add-folder <path>` (repeatable)
- `--mode history|changes`
- `--select-change <path>`
- `--select-commit <index>`

In the diff view:
- Click a changed line to select or deselect it.
- Drag to select a range.
- Shift-click to extend the selection.
- Click a hunk header to select the whole hunk.
- ⌘C copies the selected lines and Esc clears the selection.

## Not yet

- No branch graph.
- No in-app prompts for SSH passphrases or HTTPS credentials. Keys in the SSH agent or Keychain and git
  credential helpers work.
- No conflict editor. Resolve in an editor, then use Mark as Resolved.
- Syntax highlighting comes from Markdown's `Md` code highlighter for now. A dedicated code library will replace
  `Git/Diff/DiffHighlighter.swift`.
