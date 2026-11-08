# Branches, Stashes and Conflicts

## Branches on the Mac

### Switch branches

Click **Branch** in the toolbar. The popover lists **Branches** and **Remote Branches**, with the current branch first
and the branches that have commits yours doesn't next. Each row shows how far ahead or behind it is, and whether it's
**Merged into** your branch. Type in **Filter branches** to narrow the list. Click a branch to switch to it.

The sidebar's **Branches** section lists the same branches. Click one to switch, or right-click it for
**Switch to …**.

### Create a branch

- Click **New Branch…** in the popover, or **New Branch** (+) in the sidebar's **Branches** header.
- Or right-click a branch and choose **New Branch from …**, or choose **Branch from Here…** on a commit in History.

Type a name. **Switch to the new branch** is on unless you turn it off. Click **Create**.

### Merge a branch

- In **History**, click **Merge** in the toolbar and pick a branch. Each one previews what it brings in.
- Or right-click a branch and choose **Merge into …**.

If the merge stops with conflicts, Git shows **Resolve Conflicts** (below).

### Delete a branch

Right-click a branch and choose **Delete…**. Git asks how:

- **Delete** removes the local branch, but refuses one that isn't merged.
- **Force Delete** removes it anyway.
- **Delete Local and origin…** (named after its remote) also deletes the branch on the remote. A sheet shows both,
  warns about commits that exist only there, and asks you to type the branch's name to confirm. It deletes the remote
  branch only if nobody pushed to it since you last fetched.

**Copy Name** copies a branch's name.

### Worktrees

When a repository has several worktrees, the sidebar lists them under **Worktrees**, and shows which have commits your
branch doesn't.

## Branches on iPhone and iPad

Tap the branch button (it shows the branch's name):

- **Branches** lists your local branches, with the current one checked. Tap another to switch to it.
- **Remote** lists branches that exist only on the remote. Tap one to make a local branch that tracks it and switch to
  it.
- **New Branch…** starts a branch from the current one. Type a name and tap **Create**. A name with a space isn't
  allowed.

Merging, deleting branches and stashes are on the Mac only.

## Stashes (Mac)

A stash puts uncommitted changes aside, so you can switch branches with a clean working tree.

- Click **Stash** in the toolbar and choose **Stash Changes…**. You can name the stash, and turn on **Include untracked
  files**. Click **Stash**.
- **Pop Latest Stash** puts the latest stash's changes back in your files and removes the stash.
- Each stash in the menu has **Apply** (puts its changes back and keeps it), **Pop** (puts them back and removes it)
  and **Drop…** (deletes it, after asking; you can't undo this).

The **Stashes** screen (⌘3) lists every stash with the same three actions.

## Resolve conflicts (Mac)

When a merge, rebase, cherry-pick or revert stops with conflicts, the repository shows **Resolve Conflicts**. Nothing
is committed until you continue.

1. The **Conflicts** list shows each conflicted file and how many of its blocks still need a choice. Files that merged
   cleanly are listed under **Merged cleanly**.
2. Pick a file. Each conflict shows **Current** (your branch), **Incoming** (the other side), and **Base** when the
   repository records it.
3. For each block, click **Use Current** or **Use Incoming**. Or press ⌥⌘← or ⌥⌘→ to choose a side for the next open
   conflict in the file. **Change** undoes a choice.
4. When one side deleted the file, choose **Keep File** or **Delete File**.
5. For anything else, click **Edit Manually…** to edit the file yourself.
6. When the banner says **All conflicts resolved**, click **Continue Merge** (or **Continue Rebase**, **Continue
   Cherry-Pick**, **Continue Revert**). **Abort** puts everything back as it was before.

When it's done, Git says **Merge complete** (or rebase, cherry-pick, revert) with **View History** and **Push to …**.

**Edit Manually…** opens the file in its usual app. A script, launcher or other file that would run when opened goes
to a text editor, or is shown in Finder, instead.

For a repository on another device, **Edit Manually…** asks you to edit the file on that device, then come back to
continue.

On iPhone and iPad, a repository on your Mac with conflicts shows a banner. Resolve them in Git on the Mac.
