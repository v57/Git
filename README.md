# Git

A Git client for macOS: a library (`GitKit`) that does everything git-related and a small SwiftUI app (`Git`)
on top of it.

The app shows commit history, colored diffs with word-level highlights, and the working tree's
staged and unstaged files. You can:
- Stage, unstage or discard whole files, hunks or individual lines.
- Commit (with amend), undo the last unpushed commit, and revert, reset to or tag a commit from
  History.
- Fetch, pull and push with one button that picks the useful action, the way GitHub Desktop does.
- Switch, create, merge and delete branches, and stash.
- Resolve merge, rebase, cherry-pick and revert conflicts in the app: pick Current, Incoming or
  both for each conflict block, or keep or delete a file one side deleted, then Continue or Abort.
- Browse history with a branch graph, for the current branch or all branches.
- Clone a repository or create a new one from the welcome screen or the File menu.

The Worktree and Branch headers show which worktrees and branches have commits the current branch
doesn't. Drop a folder on the sidebar and every Git repository inside it is added. Repositories
that share a folder become a group named after it, with the folder above as a note (`Hub/Apps/*`
makes `Apps`, noted `Hub`); groups don't nest, so a repository deeper down joins only its own
folder's group. Drag repositories and groups to reorder or regroup them; ⌘- and ⇧-click select
several, and the context menu fetches, pulls, pushes, hides or moves them together.

The sidebar shows every repository's state without opening it: an orange dot with the number of
changed files, ↑ commits to push, ↓ commits to pull, and a merge or rebase in progress. One file
watcher covers all of them, and a group's header sums up its repositories. Collapsed, the
Repositories section still shows the open repository, and its header shows an icon for each
other repository that needs attention.

## Layout

    Package.swift                 GitKit library + GitKitTests (swift-testing)
    Sources/GitKit/
      Process/    GitRunner (argv-based process runner), GitExecutable (finds git), GitError
      Models/     WorkingTreeStatus/FileChange, Commit/RefLabel, Branch/Stash, FileDiff/DiffHunk/DiffLine,
                  ConflictedFile (conflict markers → blocks), CommitGraph (lanes for the history graph)
      Parsing/    status --porcelain=v2, log, name-status, for-each-ref, stash list, unified diff
      Staging/    PatchBuilder: patches for a subset of a diff's lines
      Discovery/  RepoDiscovery: finds repositories inside a folder; RepoGrouping: groups them by folder
      Session/    RepositorySession (@Observable state + actions), RepositoryWatcher (FSEvents)
      Repository.swift   every git operation, as async methods on a Sendable struct
    Git.xcodeproj                 the app; local packages ../Git (GitKit) and ../Code (CodeKit)
    Git/                          app sources
      Library/    SavedRepository and SavedGroup (SwiftData), RepositoryLibrary (sessions, summaries,
                  import, grouping and ordering, fetch/pull/push across repositories)
      Sidebar/    groups and repositories with their state, then Workspace, Branches, Remotes, Tags, Worktrees
      Changes/    file list, commit composer, diff cards with hunk/line actions, Resolve Conflicts
      History/    commit table with branch graph, commit inspector
      Stashes/    stashes with Apply, Pop and Drop
      Shared/     avatars, status badges, ref pills and other small views
      Diff/       DiffView (selection, copy), DiffHighlighter (the only file importing CodeKit), LoadedDiff
      Toolbar/    Fetch/Pull/Push, Branch/Merge/Stash, branch popover, sheets
      Welcome/    the Welcome window: clone, open, new repository, recent repositories

Screens, panels and selections change with one animation, `Animation.app`
(`.smooth(duration: 0.25)`): pages fade and rise, counts roll and symbols swap.

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
- **Conflicts.** `ConflictParser` splits the working-tree file at `<<<<<<<`, `|||||||` (diff3 and
  zdiff3), `=======` and `>>>>>>>`, keeping line endings. The chosen text is written in place (so the
  file keeps its permissions) and staged. Taking a whole side uses `checkout --ours/--theirs`, or
  `git rm` when that side deleted the file.
- **Branch graph.** `CommitGraph` gives each commit a lane as `git log` lists it. A parent's line
  stays in its child's lane, merges open lanes for their other parents, and a side lane folds back
  left when it reaches a commit another lane already leads to.
- **Discarding is recoverable for new files.** Untracked files are moved to the Trash rather than deleted.
- **Live updates.** `RepositorySession` watches the working tree and `.git` with FSEvents. It ignores objects,
  logs and lock files, and refreshes status, branches, stashes and, when refs move, history.
- **Syntax colors.** They come from CodeKit (`../Code`), which detects the language from the file name,
  extension or `#!` line. Each side of a diff is highlighted as a whole file and mapped onto the diff lines.
- **Not sandboxed.** The app is distributed with Developer ID and the hardened runtime, because it runs git and
  your hooks on arbitrary folders.

## Usage

```bash
swift build && swift test
xcodebuild -project Git.xcodeproj -scheme Git -destination 'platform=macOS' build
```

Debug builds accept these launch arguments for scripted screenshots:
- `--in-memory`, which keeps the repository list in memory so the real one is untouched
- `--add-folder <path>` (repeatable)
- `--mode history|changes`
- `--select-change <path>`
- `--select-commit <index>`
- `--all-branches`, which shows every branch in History
- `--welcome`, which opens the Welcome window (filled from `--add-folder`)
- `--light`, which draws the app in light mode
- `--show-branches` / `--show-worktrees`, which open those popovers

In the diff view:
- Click a changed line to select or deselect it.
- Drag to select a range.
- Shift-click to extend the selection.
- Click a hunk header to select the whole hunk.
- ⌘C copies the selected lines and Esc clears the selection.

## Not yet

- No in-app prompts for SSH passphrases or HTTPS credentials. Keys in the SSH agent or Keychain and git
  credential helpers work.
- No inline editing in the conflict editor. Use Open for edits beyond picking sides, then Mark as
  Resolved.
