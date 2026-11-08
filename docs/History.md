# History

## On the Mac

Open a repository's **History** (⌘2). From the top:

- **To pull**: commits on the upstream branch that you don't have yet, with **Pull**.
- **To push**: your commits that aren't on the remote yet, with **Push**.
- The history, with a branch graph.

The switch under the list shows **All Branches** or the **Current Branch** only. Next to it, Git counts the commits
and their authors. Older commits load as you scroll to the end.

### Search

Type in the toolbar's search field (**Message, author, hash**) to find commits by their message, author or hash.

### Look at a commit

Click a commit. The inspector shows its message, author and date, and the files it changed. Click the short hash to
copy the full one. Pick a file to see its diff, and click **Open Diff** to see it larger.

Use ↑ and ↓ to move through the commits. Hold ⇧ to select several.

### Act on a commit

The inspector has:

- **Check Out**: puts you on this commit without a branch. It asks first. Create a branch to keep work you do there.
- **Revert…**: makes a new commit that undoes this commit's changes. It asks first.
- **Cherry-Pick**: makes a new commit on your branch with this commit's changes.
- **More Actions**: **Branch from Here…**, **Tag…**, **Push Tag** for each tag on the commit, **Copy SHA** and
  **Copy Message**.

Right-click a commit in the list for **Check Out**, **Revert Changes**, **Cherry-Pick** and **Reset to Here…**.

**Reset to Here…** moves your branch back to this commit. The later commits leave the branch, but their changes stay in
your files, so you can commit them again. It asks first.

If a revert or cherry-pick stops with conflicts, Git shows **Resolve Conflicts**. See
[Branches, Stashes and Conflicts](Branches-Stashes-and-Conflicts.md#resolve-conflicts-mac).

### Squash commits

1. Select commits that follow one another on the current branch: ⇧-click them, or use ⇧↑ and ⇧↓.
2. Right-click and choose **Squash N Commits…**.
3. Write the new commit's **Summary** and **Description**, then click **Squash** (⌘↩).

The new commit keeps the oldest commit's author. Your working tree isn't touched, so nothing conflicts. If some of the
commits are already pushed, Git warns you: you'll need **Force Push** to replace them on the remote.

With several commits selected, **Copy SHAs** copies their hashes.

### Tags

The sidebar's **Tags** section lists the repository's tags. Its header names the latest one.

- Click a tag, or choose **Show in History**, to find its commit.
- **Copy Name** copies it.
- **Push Tag** sends it to the remote with the commits it needs. A tag the remote already has is never moved.
- **New Tag** (+) tags the current commit. **Tag…** in a commit's **More Actions** tags that commit. Give it a
  **Name**, and a **Message** if you want an annotated tag.

## On iPhone and iPad

Tap **History** at the top of a repository. The card shows the branch, how many commits it has, and how many are still
to push. Each row shows the author, subject, date, a ↑ for a commit that isn't pushed, up to three branch or tag
labels, and the short hash. Older commits load as you scroll. Pull down to refresh.

Tap a commit to see its subject, message, author and date, its full hash (you can select and copy it) and the files it
changed. Tap a file to see what the commit changed in it.

Commit actions such as revert, cherry-pick, reset, squash and tags are on the Mac only.
