# Fetch, Pull, Push and GitHub

## On the Mac

The toolbar has three buttons:

- **Fetch** (⇧⌘F) checks the remotes for new commits. Nothing in your branch changes. Its tooltip says when you last
  fetched.
- **Pull** (⇧⌘P) brings the upstream branch's new commits into your branch. It needs a branch with an upstream.
- **Push** (⌘P) sends your commits, and shows how many there are. On a branch without an upstream it reads
  **Publish**: it pushes the branch and tracks it. In a repository with no remote, **Publish** opens **Publish to
  GitHub** (below).

The same commands are in the **Repository** menu. The sidebar's **Remotes** section has its own **Fetch**, and a
remote's row fetches just that remote. To fetch, pull or push several repositories at once, see
[Repositories](Repositories.md#work-with-several-repositories-at-once).

### Force push

Right-click **Push** and choose **Force Push…**. Its preview shows the commits the remote would lose. Git asks first,
and a force push refuses if someone else pushed since your last fetch.

## On iPhone and iPad

One **Sync** button does what's useful now:

- **Pull N** when the remote has commits you don't.
- **Push N** when you have commits the remote doesn't.
- **Publish** for a branch with no upstream: it pushes the branch and tracks it.
- **Fetch** otherwise.

It's off when the repository has no remote. While it runs, the title shows its progress. If it fails, a notice such as
**Couldn’t Push** gives the server's message.

For repositories on the device:

- **Pull** only fast-forwards. If your branch and the remote have both moved, it reports an error.
- **Push** sends the current branch only, and never forces.
- Submodules, Git LFS, shallow clones and SHA-256 repositories aren't supported yet.

For repositories on your Mac, the Mac's git does the work, with its own config, hooks and credentials. If the Mac
can't sign in over SSH, Git may offer to switch the remote to HTTPS: **Switch and Push** (or Pull, Fetch) changes the
remote's address and tries again. Without a GitHub sign-in in Git, that needs the Mac's own git credentials.

## Sign in to GitHub

Signing in lets Git clone and push private repositories, and on the Mac publish new ones.

1. Open **Settings ▸ GitHub** and click **Sign In…**.
2. Choose what Git may do. Under **Repositories**, pick **Public and private** or **Public only**. Turn
   **Organizations** and **Workflows** on or off. The sheet lists the GitHub scopes it will ask for.
3. Click **Continue on GitHub**. Git copies a code and opens github.com/login/device in your browser.
4. Paste the code on GitHub and approve. Back in Git, **Copy Code** and **Open GitHub Again** help if you need them.
   The sheet counts down until the code expires.
5. When you see **Connected as …**, click **Done**.

If GitHub grants less than Git asked for, the sheet says so. Git asks again when something needs the missing
permission.

Once signed in, **Settings ▸ GitHub** shows your picture, name and profile link, and a **Permissions** card for
**Private repositories**, **Organizations** and **Workflows**: each is **Granted** or has **Grant…**. **Change
Permissions…** reopens the sheet. **Sign Out** signs you out.

- The sign-in for your personal vault account is shared with Markdown and Dev on the same device. Signing out in Git
  signs them out too.
- On the Mac, each vault account has its own GitHub sign-in. When another account is signed in, Git offers to **Use**
  it.
- If a push changes files in `.github/workflows` and GitHub refuses it for a missing permission, the error offers
  **Grant Access…**.

## Publish to GitHub (Mac)

A repository with commits but no remote can go to GitHub in one step.

1. Click **Publish** in the toolbar, or choose **Repository ▸ Publish to GitHub…** (⌘P).
2. Pick the **Owner**: you, or one of your organizations. Only organizations where your membership is public are
   listed.
3. Check the **Name**, add a **Description** if you want, and pick **Private** or **Public** under **Visibility**.
4. Click **Publish**.

Git creates the repository on GitHub and pushes your branch to it as `origin`. If you aren't signed in, the sheet has
**Sign In…**. If your sign-in only allows public repositories or lacks organizations, it has **Grant…**.

## Fetch automatically

Auto-fetch is off until you turn it on, in **Settings ▸ Privacy ▸ Auto-fetch**. It's set per device.

- **Fetch automatically** turns it on.
- **When**: **At Startup** fetches the repositories on this device when Git starts. **When Selected** fetches a
  repository when you select it. **Both** does both.
- **Each repository, at most**: **Once an Hour**, **Once a Day** or **Once a Week**.

An automatic fetch is an ordinary fetch at your security level. A failed one stays quiet. At **SSH only** and above,
repositories with HTTPS remotes wait until you fetch, pull or push yourself. At **Vault key only**, repositories on
your other devices are left out. Repositories on other devices are never fetched at startup.

## Security levels and remotes

**Settings ▸ Security** decides how clone, fetch, pull and push sign in. At **SSH only** and **Vault key only**,
HTTPS remotes move to SSH the next time you use them. When a remote can't move yet, for example because GitHub doesn't
know this device's key, Git explains why and offers:

- **Add Key on GitHub**: copies this device's key and opens GitHub's page for adding it. Then try again.
- **Use HTTPS This Time**: runs this one action over HTTPS with your GitHub sign-in. The remote stays on HTTPS, and
  the next action asks again.

See [Privacy and Security](Privacy-and-Security.md#security-levels).
