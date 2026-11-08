# Privacy and Security

Git contacts no server on its own. Nothing goes to v57: there's no server of ours, no analytics, no crash reporter and
no ads. **Settings ▸ Privacy** lists everyone Git talks to.

## What Git sends over the network

| Who | When | What they see |
|---|---|---|
| The servers your remotes name (GitHub, GitLab, your own) | When you clone, fetch, pull, push or delete a remote branch, and when auto-fetch runs if you turned it on. | Your IP address, your sign-in, and what you push. |
| Whatever your git setup names (Mac) | At **Use git**, and where Git hands an action to your git: a `pre-push` hook, Git LFS, submodules, or a remote set up with its own SSH command. | Whatever git sends with your own keys and helpers. Your GitHub token only at **Use git**. |
| GitHub (github.com, api.github.com) | When you sign in, open **Settings ▸ GitHub**, open **Publish to GitHub** or publish a repository. | Your sign-in. Git reads your name, picture and organizations. Launching Git doesn't contact GitHub. |
| GitHub, for your picture | While **Settings ▸ GitHub** shows it. | Your IP address. Commit authors show as letters, not pictures. |
| GitHub, for updates (Mac) | When you choose **Check for Updates…**, or once a day if **Check for updates automatically** is on. It's off until you turn it on. Downloads start only when you say so. | Your IP address. |
| Apple (iCloud) | While iCloud is on for this device. | Encrypted records only. See below. |
| Your other devices, over SSH | When you open a repository on one, or act on one (**Fetch All** and the like). While it's open, Git checks it every few seconds. | Your sign-in with this device's key, and the git commands Git runs there. |

Links you click open in your browser, which talks to those sites itself.

On the Mac, while **Settings ▸ Remote** is open, Git checks every few seconds whether Remote Login answers on the Mac
itself. Nothing leaves the Mac.

### What starts on its own

Only what you turned on:

- **Check for updates automatically** (Mac): off by default.
- **Fetch automatically**: off by default. When on, it fetches at startup, when you select a repository, or both, at
  most once an hour, day or week per repository.

When Git starts, it doesn't connect to your other devices. On the Mac, a repository on another device that was open
when you quit waits for you to click **Connect**.

## iCloud

iCloud is on when you use iCloud on the device. Git syncs through your vault, and every record is encrypted on the
device before it goes to iCloud. Apple sees only an item id, a key id and the encrypted data.

What syncs: your repositories (as vault projects) and their groups, the security level, your devices' public keys,
and each repository's last state: its branch, change and commit counts, up to 100 changed file names, and dates. That's
what lets your iPhone show a Mac repository's changes before it connects. Your files and commits don't go to iCloud.

**Settings ▸ Privacy ▸ Use iCloud** turns iCloud off for every v57 app on this device. Git asks first. What's already
in iCloud stays there.

## What Git keeps on your device

- **Your GitHub token:** in the keychain, never in git's credential helpers or the `gh` tool. Your personal
  account's sign-in is shared with Markdown and Dev, and syncs with iCloud Keychain.
- **This device's SSH key:** in the device's Secure Enclave. See below.
- **Server keys:** in your vault. At **Use git**, ssh keeps its own `known_hosts`.
- **Your repositories:** in their folders, as git keeps them. Git doesn't encrypt them. On the Mac, FileVault does. On
  iPhone and iPad, they're in Git's folder, which the Files app shows.
- **Auto-fetch settings:** on this device only.

## This device's key

Git signs in to SSH servers, GitHub and your other devices with a key made inside this device's Secure Enclave, a chip
nothing can copy it out of, not even Git.

- A key made since November 4, 2026 signs only once you confirm with Face ID, Touch ID or your password. That yes
  lasts 15 minutes in Git.
- An older key signs while the device is unlocked, without asking.

**Settings ▸ Security** says which kind this device has. **Settings ▸ Security ▸ SSH Key** shows the key's fingerprint,
with **Copy** and **Add on GitHub**.

## Server keys

The first time Git connects to an SSH server, it asks **Trust this server's key?** and shows the key's fingerprint.
Nothing is sent to the server before you answer. Trust it only if it's the right key: anyone on the network could be
answering in its place. **Trust and Connect** remembers the key. A server whose key changes later is refused.

## Security levels

**Settings ▸ Security ▸ Minimum level** decides how far clone, fetch, pull and push may go, on all your devices.
Status, commit, merge and rebase run git at every level, and never see a key or token.

- **Use git** (Mac only): git with your own setup, plus your GitHub token in its environment, where anything git runs
  (a hook, say) can read it.
- **In-app first** (the default): Git signs in itself, with this device's key or your GitHub token. If that can't
  work, it runs git with your own keys and helpers, never the token. A repository with a `pre-push` hook or Git LFS
  goes straight to git.
- **SSH only**: as above, and HTTPS remotes move to SSH the next time you use them, once SSH works. HTTPS is refused.
  If you lower the level, they move back.
- **Vault key only**: Git never runs git on the network, and only this device's key signs in. HTTPS remotes move to
  SSH. `pre-push` hooks don't run, `~/.ssh/config` isn't read, and submodules, LFS and folder remotes are refused, with
  the reason.

Raising the level asks first: SSH stops working until this device's key is on each server.

Repositories on your other devices use that device's git and keys. At **SSH only**, Git warns that the level isn't
enforced there. At **Vault key only**, fetch, pull and push are off for them.

On Linux and Windows there's no Security pane: network actions always run your installed git.

## Your GitHub token

Git uses the token itself, and only over HTTPS. It never sends it over plain HTTP, or to another host after a
redirect. Below **Use git**, git on your Mac never gets it. For a Mac repository opened from an iPhone or iPad, the
Mac's git gets the token only after you accept switching that remote to HTTPS, and only for that host.

## Repositories you didn't make

- **Opening a repository doesn't run its commands.** Every git command Git runs has `core.fsmonitor` turned off, so a
  repository whose `.git/config` names a monitor command can't run it when Git lists its changes. Other commands a
  repository's own config can name, such as filters, still run as they would in Terminal, so add only folders you
  trust.
- **Clones on iPhone and iPad stay in their folder.** When you clone, pull or switch branches, Git refuses file names
  git itself wouldn't check out (such as `..` or `.git` in any spelling). A hostile server can't write into another
  repository, Git's settings, or the repository's own `.git`.
- **Edit Manually… doesn't run scripts.** In the conflict editor, a conflicted script, launcher or executable opens in
  a text editor, or is shown in Finder, instead of in the app that would run it.
- **Discarded new files go to the Trash** on the Mac, so a mistaken discard can be undone.

## The Mac app isn't sandboxed

Git on the Mac runs git and your hooks on any folder you add, so it can't run in the App Sandbox. It's signed with a
Developer ID and notarized.
