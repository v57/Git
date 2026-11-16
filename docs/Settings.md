# Settings

Settings is where you pick the git Git runs, sign in to GitHub, choose how network actions sign in, and turn on the
things that are off by default: automatic fetching and update checks. Under the panes, **Copy Public Key** copies this
device's SSH key, to add to GitHub or a server.

## On the Mac

<!-- only: mac -->
Choose **Git ▸ Settings…** (⌘,).
<!-- /only -->
<!-- only: linux -->
On Linux, choose **Edit ▸ Preferences…** (Ctrl+,).
<!-- /only -->

### General

- **git executable**: the path of the git to run. Leave it empty to find one automatically (see
  [Getting Started](Getting-Started.md#check-that-git-is-installed)). **Using** shows the git Git found and its
  version, or **git not found**.
- **Terminal ▸ Commits as**: who git in Terminal, scripts and agents commits as, from `~/.gitconfig`. **Use …** writes
  your vault name there. Git itself commits with your name either way.

### GitHub

Sign in to GitHub, see what Git may do, grant more, or sign out. With more than one vault account, pick the account at
the top; it follows the frontmost window. See [Fetch, Pull, Push and GitHub](Syncing-and-GitHub.md#sign-in-to-github).

### Security

On the Mac only; the Linux and Windows apps have no Security pane, and their network actions always run your own git.

- **What protects your work**: how this device's key, your GitHub sign-in, the servers you connect to, your
  repositories and what syncs are protected at the current level.
- **Security level ▸ Minimum level**: **Use git**, **In-app first**, **SSH only** or **Vault key only**. Raising the
  level asks first. All your devices share the level.
- A comparison of how other Git apps keep your key, token and git setup.
- **SSH Key**: this device's key, its fingerprint, **Copy**, and **Add on GitHub**.

See [Privacy and Security](Privacy-and-Security.md#security-levels).

### Privacy

- **Updates**: **Check for updates automatically**, off by default, and when Git last checked.
- **Auto-fetch**: off by default. See [Fetch automatically](Syncing-and-GitHub.md#fetch-automatically).
- **iCloud ▸ Use iCloud**: on or off for every v57 app on this device. Turning it off asks first. On Linux and Windows
  the card says iCloud is only on Apple devices.
- The list of everyone Git talks to, and when. See [Privacy and Security](Privacy-and-Security.md).

### Accounts

Your vault accounts: your personal one, and any you work for. **New Account…** adds one. Each Git window uses one
account, picked at the top of its sidebar.

### Remote

Lets your iPhone, iPad and other devices sign in to this Mac, so Git there can work on this Mac's repositories. See
[Repositories on Other Devices](Other-Devices.md#let-your-devices-in). On Linux and Windows this pane lists your
devices to rename or remove.

## On iPhone and iPad

On iPhone, tap the gear at the bottom of the repository list. On iPad, the gear opens Settings over the whole window;
**Done** puts the repository list back. The panes are **GitHub**, **Security**, **Privacy** and **Devices**.

### GitHub

Sign in to GitHub, see what Git may do, grant more, or sign out. See
[Fetch, Pull, Push and GitHub](Syncing-and-GitHub.md#sign-in-to-github).

### Security

The same pane as on the Mac, with **In-app first**, **SSH only** and **Vault key only**: there's no git program on
iPhone and iPad, so **Use git** isn't offered.

### Privacy

**Auto-fetch**, **iCloud ▸ Use iCloud**, and the list of everyone Git talks to. There's no update check here.

### Devices

**Your Devices** lists this device first, then your other devices with their platform and number of projects. Touch
and hold a device for **Rename…**, **Remove…** and **Lost Device…**. A lost device moves to **Not Trusted**, where
**Trust Again…** brings it back. These settings are shared with the other v57 apps; see the
[Vault guide](https://github.com/v57/Vault/blob/main/docs/README.md).
