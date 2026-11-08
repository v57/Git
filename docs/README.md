# Git user guide

Git is a Git client for your Mac, iPhone and iPad. It shows every repository you work on with its state at a glance,
and lets you stage whole files, hunks or single lines, commit, browse history, switch and merge branches, and fetch,
pull and push. On iPhone and iPad it works on repositories stored on the device, and on repositories on your Mac,
whose own git it runs over SSH.

## Platforms

- **Mac:** the full app. It runs the git installed on your Mac, so your config, hooks and commit signing apply. It
  has line staging, conflict resolution, stashes, a branch graph, squash, tags and Publish to GitHub. The Mac app is
  a direct download from GitHub Releases.
- **iPhone and iPad:** two kinds of repositories.
  - **On this device:** clone or create a repository in Git's folder, which the Files app shows under **Git**. Git
    has its own git engine here, with no git program: changes and diffs, staging whole files, discarding, commits,
    history, branches, fetch, fast-forward pull and push.
  - **On your Mac:** open a repository on a Mac (or any SSH host) and Git runs that machine's git over SSH. Everything
    the Changes screen does works there, line staging and amend included, and that machine's config, hooks and
    credentials apply.
- **Linux and Windows:** the desktop app also builds for Linux and Windows. It has the Mac app's screens and runs
  the git installed there for every network action. It has no **Security** pane and no iCloud sync.

## Pages

- [Getting Started](Getting-Started.md): add your first repositories and find your way around.
- [Repositories](Repositories.md): the repository list, groups, sorting and filters, and adding or removing
  repositories.
- [Changes and Commits](Changes-and-Commits.md): staging files, hunks and lines, discarding, and committing.
- [History](History.md): the commit list, the branch graph, and actions on commits and tags.
- [Branches, Stashes and Conflicts](Branches-Stashes-and-Conflicts.md): switching, creating, merging and deleting
  branches, stashing, and resolving conflicts.
- [Fetch, Pull, Push and GitHub](Syncing-and-GitHub.md): syncing with remotes, GitHub sign-in, Publish to GitHub and
  auto-fetch.
- [Repositories on Other Devices](Other-Devices.md): working on your Mac's repositories from an iPhone or iPad, and
  letting your devices in.
- [Settings](Settings.md): every settings pane, on the Mac and on iPhone and iPad.
- [Privacy and Security](Privacy-and-Security.md): what Git sends over the network, the security levels, this
  device's key, and how Git handles untrusted repositories.
- [Keyboard Shortcuts](Keyboard-Shortcuts.md): menu commands and keys on the Mac, and keys in sheets on iPad.

## Works with other v57 apps

- [Vault](https://github.com/v57/Vault/blob/main/docs/README.md): your repositories, their groups, your name for
  commits, your devices, SSH hosts and this device's key live in the shared vault. Every v57 app on every device sees
  the same projects and groups.
- [Hub](https://github.com/v57/hub-app/blob/main/docs/README.md): projects on the devices of your Hub show up under
  **On Your Devices** on iPhone and iPad.
- [Markdown](https://github.com/v57/Markdown/blob/main/docs/README.md) and Dev: the GitHub sign-in is shared. Signing
  in or out in Git signs in or out there too.
- [Code](https://github.com/v57/Code/blob/main/docs/README.md): Git's diffs use Code's syntax colors, and on the Mac a
  repository's menu can open it in Code.
- [Shell](https://github.com/v57/Shell/blob/main/Docs/README.md): Shell can open a folder in Git.

## Network

Git contacts no server on its own. It talks to your Git servers when you clone, fetch, pull or push, to GitHub when
you sign in or open its settings, and to your other devices when you open a repository there. Automatic fetching and
the Mac's update check are off until you turn them on. See [Privacy and Security](Privacy-and-Security.md) for the
full list.
