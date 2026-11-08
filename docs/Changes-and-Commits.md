# Changes and Commits

## See what changed

Open a repository's **Changes** screen (⌘1 on the Mac). Changed files sit in two cards:

- **Unstaged**: changes that won't go into the next commit yet.
- **Staged**: changes that will. While it's empty, it says to tick a file below.

Each row shows a badge for the kind of change (modified, added, deleted, renamed or new), the file's name and folder
(or the old path for a rename), and the lines added and removed. Select a file to see its diff. On iPhone, tap a file
to open its diff.

When nothing changed, Git says the working tree matches the branch. On the Mac, **View History** takes you to the
commits.

On iPhone and iPad, pull down on **Changes** to refresh. On the Mac, Git refreshes as files change. For a repository
on another device, it checks for changes every few seconds.

## Stage and unstage

### Whole files

- Tick a file's checkbox to stage it. Untick it to unstage it.
- **Stage All** on the **Unstaged** card stages everything. **Unstage All** on the **Staged** card does the reverse.
- A file's menu (right-click on the Mac, touch and hold on iPhone and iPad) has **Stage** or **Unstage**.
- In a diff, **Stage File** or **Unstage File** (on iPhone and iPad, **Stage** or **Unstage** in the bar) moves the
  file you're looking at.

### Hunks and lines

Each change in a diff is a card, with syntax colors and word-level highlights.

- **Stage Hunk** stages the whole card.
- Click changed lines to select them, and ⇧-click to select a range. Then click **Stage N Lines**. Point at a line
  and click its **+** to stage just that line.
- In a staged diff, **Unstage** takes the whole card out, and **Unstage N Lines** takes out the lines you selected.
- ⌘C copies the selected lines. A line's menu has **Copy Line**.

On iPhone and iPad, hunk and line staging works for repositories on your Mac. Repositories on the device show diffs
as read-only cards: stage them as whole files.

When **View ▸ Hide Whitespace Changes** is on, diffs leave out whitespace-only changes, and you stage whole files.

A very large diff still opens, but past 20,000 lines it shows without syntax colors.

## Discard changes

Discarded changes to tracked files can't be got back, so Git asks first.

- A file's menu has **Discard Changes…**.
- A card's menu has **Discard All…**.
- On the Mac, a diff's header has **Discard…**, and selected lines can be thrown away with **Discard Lines…**. A
  card's menu has **Discard Hunk…**, which asks first.

On the Mac, new files you discard are moved to the Trash, so you can get them back. On iPhone and iPad:

- in a repository on the device, new files are deleted;
- in a repository on your Mac, new files are moved to the Trash there.

## Ignore a file (Mac)

A changed file's menu has **Add to .gitignore**. For a file with an extension, it's a submenu that also offers
**All .ext Files**.

## Open a file (Mac)

A changed file's menu opens it in its usual app or another app, shows it in Finder, or copies its path with **Copy
Path**. On iPhone and iPad, the file's menu has **Copy Path**.

## Commit

### On the Mac

1. Stage what you want to commit.
2. Type a summary. Git may suggest one: press Tab in the empty field to take it. A counter shows when you pass 50
   characters, the length logs and tools keep.
3. Press Return to move to the description, and say why you made the change.
4. Click **Commit N Files** (⌘↩), or **Commit & Push** (⇧⌘↩) to push right after.

After a commit, a notice says **Committed “…” to main** for 20 seconds. It has **Undo**, which takes the commit back,
keeps your changes staged and puts its message back in the box. It also has **Push** (or **Publish…** when the
repository has no remote).

**Amend last commit** replaces the last commit with the staged changes and the message you type. Ticking it fills in
the last commit's message.

### On iPhone and iPad

1. Type a summary in the box under the changes. With a hardware keyboard, Return starts a new line. It doesn't commit.
2. Tap **Commit N Files**. If nothing is staged, Git stages every change first.

For a repository on your Mac, an **Amend** switch replaces the last commit. Repositories on the device don't offer
amend.

### Who the commit is from

Git uses the repository's own name and email first, then **Your Name** from your vault. If neither names you, the
first commit asks for your name and email in the **Your Name** sheet. **Cancel** stops the commit. **Save** keeps them
in your vault, for every v57 app and device.

## Conflicted files

When a merge, rebase, cherry-pick or revert stops with conflicts, the Mac shows **Resolve Conflicts**. See
[Branches, Stashes and Conflicts](Branches-Stashes-and-Conflicts.md#resolve-conflicts-mac).

On iPhone and iPad, a repository on your Mac with conflicts shows a banner, **N Conflicted Files**. Resolve them in
Git on the Mac, then come back to commit.
