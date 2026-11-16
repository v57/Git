# Getting Started

Install Git, add your first repositories and find your way around. Pick your platform: the Mac, Linux and Windows app
works on repositories on your computer with the `git` you have installed; on iPhone and iPad, Git keeps repositories on
the device or works on the ones on your Mac.

## On the Mac

### Install

<!-- only: mac -->
Download **Git.dmg** or **Git.zip** from [Git's releases on GitHub](https://github.com/v57/Git/releases) and move
**Git** to your Applications folder. It needs macOS 15 or later on a Mac with Apple silicon.
<!-- /only -->
<!-- only: linux -->
On Linux, download **Git-Linux-x64.tar.gz** or **Git-Linux-arm64.tar.gz** from
[Git's releases on GitHub](https://github.com/v57/Git/releases). It holds the app's folder, with a `.desktop` file and
its icon, made to go in `/opt/Git`.
<!-- /only -->
<!-- only: windows -->
On Windows, download **Git-Windows-x64.zip** or **Git-Windows-arm64.zip** from
[Git's releases on GitHub](https://github.com/v57/Git/releases), unzip it and open **Git** from the folder.
<!-- /only -->

### Check that git is installed

Git runs the `git` program installed on your computer, so your config, hooks and commit signing apply. It looks for
the path set in **Settings ▸ General ▸ git executable** first, then:

<!-- only: mac -->
- on the Mac: Homebrew's git (`/opt/homebrew/bin/git`, `/usr/local/bin/git`), then `/usr/bin/git`, which needs
  Apple's Command Line Tools (`xcode-select --install`).
<!-- /only -->
<!-- only: linux -->
- on Linux: `/opt/homebrew/bin/git`, `/usr/local/bin/git`, then `/usr/bin/git`. Install git with your distribution's
  package manager if none is there.
<!-- /only -->
<!-- only: windows -->
- on Windows: the `git.exe` on your `PATH`, then Git for Windows in Program Files or in your user's programs folder.
<!-- /only -->

**Settings ▸ General** shows the git it found and its version under **Using**, or **git not found**.

### Add your repositories

With no repository open, the window shows the welcome screen: three ways in, and your recent repositories with their
state.

- **Clone Repository…** copies a repository from GitHub, GitLab or any URL. Type the **Repository URL**, check the
  **Name**, pick a **Location** with **Choose…** (your `~/Developer` folder when you have one), then click **Clone**.
- **Open Local Repository…** adds a folder that has a `.git` directory. You can pick several.
- **New Repository…** starts tracking a folder.

You can also drop a folder on the sidebar or the welcome screen, or choose **File ▸ Add Folder…**. Every Git repository
inside the folder is added. If the folder has no repository, Git asks whether to **Create Repository** there.
Repositories that share a folder become a group named after it. See [Repositories](Repositories.md).

### Find your way around

- **The sidebar** lists your repositories with their state: an orange dot with the number of changed files, ↑ for
  commits to push and ↓ for commits to pull. Click one to open it.
- Under the open repository, the sidebar shows **Changes**, **History** and **Stashes**, then its **Branches**,
  **Remotes**, **Tags** and, when it has several, **Worktrees**.
- **The toolbar** has **Fetch**, **Pull** and **Push** (one button that picks the useful one), then **Branch**,
  **Merge** (in History) and **Stash**.
- **View ▸ Changes** (⌘1) is where you stage and commit. **View ▸ History** (⌘2) shows the commits. **View ▸
  Stashes** (⌘3) lists your stashes.
- The **Repository** menu has **Refresh**, **Fetch**, **Pull**, **Push** (or **Publish to GitHub…**), **Stage All**
  and **Unstage All**.

<!-- only: linux windows -->
On Linux and Windows, the shortcuts written with ⌘ in this guide use Ctrl: Ctrl+1 for Changes, Ctrl+Shift+O for Add
Folder. Settings is **Edit ▸ Preferences…** on Linux.
<!-- /only -->

### Your name on commits

Git uses a repository's own `user.name` and `user.email` first. Otherwise it uses **Your Name** from your vault,
which every v57 app and device shares. If nothing names you, your first commit asks for your name and email once.

For your personal account, your first such commit also offers **Use in Terminal too**: **Use in Terminal** writes the
name to `~/.gitconfig`, so git in Terminal, scripts and agents commits as you. **Only in Git** leaves it alone. You can
change it later in **Settings ▸ General ▸ Terminal**.

## On iPhone and iPad

### Clone or create a repository on the device

1. In the sidebar, find the card **On This iPhone** (or **On This iPad**) and tap **+**.
2. Choose **Clone Repository…** or **New Repository…**.
3. For a clone, type a URL: `owner/repo`, a GitHub address, an HTTPS URL or an SSH address all work. Tap **Clone**.
   For a new repository, type a name and tap **Create**.

The repository lives in Git's folder, which the Files app shows under **On My iPhone ▸ Git** (or iPad). A repository
you copy into that folder with the Files app shows up when you switch back to Git.

Public repositories clone as they are. To clone a private GitHub repository, sign in to GitHub first
(**Settings ▸ GitHub**), or use an SSH address, which signs in with this device's key.

### Try a sample repository

To look around before using a repository of your own, tap **Try a Sample Repository**: on the iPad welcome screen,
in the **+** menu of **On This iPhone** (or **On This iPad**), or in that card while it's empty. Git makes **Atlas
Sample** on the device and opens it: a small Swift package with a history by four made-up people, a
`feature/offline-maps` branch with commits of its own, and a changed file and a new one left to stage and commit.
Nothing is downloaded. Delete it like any other repository when you're done.

### Open a repository on your Mac

Your Mac's repositories show up under **On Your Devices** when your Mac is one of your Hub's devices, or once you open
a folder there with **Open on a Mac**. See [Repositories on Other Devices](Other-Devices.md).

### Find your way around

- **On iPhone**, tap a repository to open it. **Back** returns to the list. The **Settings** gear sits at the bottom
  of the list, next to the number of your devices.
- **On iPad**, the list stays beside the open repository. With nothing open, the welcome screen offers **Clone
  Repository…**, **New Repository…**, **Open on a Mac…** and **Try a Sample Repository**, and lists every
  repository.
- Type in **Search Repositories** at the top of the list to filter it.
- A repository's screen has **Changes** and **History**. Its title shows the branch, commits to push (↑) and pull (↓),
  and where it is: on this device, or on another device by name.
- The **Sync** button and the branch menu sit in a bottom bar on iPhone and lead the bar on iPad.

## Next

- [Changes and Commits](Changes-and-Commits.md): stage files, hunks or lines and commit.
- [Fetch, Pull, Push and GitHub](Syncing-and-GitHub.md): sync with your remotes and sign in to GitHub.
- [Keyboard Shortcuts](Keyboard-Shortcuts.md): every menu command and its keys.
