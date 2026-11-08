# Getting Started

## On the Mac

### Before you start

Git runs the `git` program installed on your Mac. It looks for a path you set in **Settings ▸ General**, then
Homebrew's git, then the system's git (which needs Apple's Command Line Tools). **Settings ▸ General** shows which git
it uses under **Using**, or **git not found**.

### Add your repositories

With no repository open, Git's window shows its welcome screen, with three ways in and your recent repositories:

- **Clone Repository…** copies a repository from GitHub, GitLab or any URL. Type the **Repository URL**, check the
  **Name**, pick a **Location** with **Choose…**, then click **Clone**.
- **Open Local Repository…** adds a folder that has a `.git` directory.
- **New Repository…** starts tracking a folder.

You can also drop a folder on the sidebar, or choose **File ▸ Add Folder…**. Every Git repository inside the folder is
added. If the folder has no repository, Git asks whether to **Create Repository** there.

Repositories that share a folder become a group named after it. See [Repositories](Repositories.md).

### Find your way around

- **The sidebar** lists your repositories with their state: an orange dot with the number of changed files, ↑ for
  commits to push and ↓ for commits to pull. Click one to open it.
- Under the open repository, the sidebar shows **Changes**, **History** and **Stashes**, then its **Branches**,
  **Remotes**, **Tags** and, when it has several, **Worktrees**.
- **The toolbar** has **Fetch**, **Pull** and **Push**, then **Branch**, **Merge** (in History) and **Stash**.
- **Changes** (⌘1) is where you stage and commit. **History** (⌘2) shows the commits. **Stashes** (⌘3) lists your
  stashes.

### Your name on commits

Git uses a repository's own `user.name` and `user.email` first. Otherwise it uses **Your Name** from your vault,
which every v57 app and device shares. If nothing names you, your first commit asks for your name and email once.
For your personal account, Git may also offer **Use in Terminal too**, which writes the name to `~/.gitconfig` so git
in Terminal commits as you. Choose **Only in Git** to leave Terminal alone. You can change this later in
**Settings ▸ General ▸ Terminal**.

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

### Open a repository on your Mac

Your Mac's repositories show up under **On Your Devices** when your Mac is one of your Hub's devices, or once you open
a folder there with **Open on a Mac**. See [Repositories on Other Devices](Other-Devices.md).

### Find your way around

- **On iPhone**, tap a repository to open it. **Back** returns to the list. The **Settings** gear sits at the bottom
  of the list, next to the number of your devices.
- **On iPad**, the list stays beside the open repository. With nothing open, the welcome screen offers **Clone
  Repository…**, **New Repository…** and **Open on a Mac…**, and lists every repository.
- A repository's screen has **Changes** and **History**. Its title shows the branch, commits to push (↑) and pull (↓),
  and where it is: on this device, or on another device by name.
- The **Sync** button and the branch menu sit in a bottom bar on iPhone and lead the bar on iPad.

## Next

- [Changes and Commits](Changes-and-Commits.md)
- [Fetch, Pull, Push and GitHub](Syncing-and-GitHub.md)
