# Repositories on Other Devices

Git on an iPhone or iPad can work on the repositories on your Mac. It signs in to the Mac over SSH with this device's
key, and runs the Mac's own git there. Everything the Changes screen does works, line staging and amend included, and
the Mac's config, hooks and credentials apply. Git on a Mac can open another Mac's repositories the same way.

## Let your devices in (on the Mac)

1. Turn on Remote Login on the Mac. If it's off, **Settings ▸ Remote** in Git says **Remote Login Is Off** and offers
   **Open Sharing…**, which opens System Settings ▸ General ▸ Sharing.
2. In **Settings ▸ Remote**, turn on **Let Your Devices In**.
3. Under **Can Sign In**, turn on each device that may sign in to this Mac.

**Sign In with a Password** is off by default, which is the safest choice. **Other Keys** lists other keys that can
sign in to this Mac as you, and **Add Key…** adds one. These settings are shared by the v57 apps; see the
[Vault guide](https://github.com/v57/Vault/blob/main/docs/README.md) for the details.

## Find your Mac's repositories (iPhone and iPad)

Projects on the devices of your Hub show up under **On Your Devices**, in the same groups as on the Mac. Your vault
syncs them through iCloud, so it can take a minute after launch for them to appear. The sidebar's bottom bar counts
your devices that have projects.

To open a folder on any machine you can sign in to:

1. Tap **+** on **On Your Devices** (**Open on a Mac**). On iPad, the welcome screen also has **Open on a Mac…**.
2. Pick the **Device**. The list holds the SSH hosts saved in the Vault app; hosts reached through your Hub say
   **Through Hub**.
3. Type the repository's **Folder** there. `~` is your home folder on that machine.
4. Tap **Open**.

The folder appears under **Opened on a Mac**. If you have no SSH host yet, the sheet says to add your Mac in the
Vault app first, as an SSH host or through your Hub. A folder that isn't a repository gives an error saying so.

## Open a repository on another device

Tap it. Git shows **Connecting to …** with what that device last reported and how long ago (**Last seen on …**): the
number of changes, the branch and some of the changed files. The **Changes** screen already lists those files, and
switches to the live state once Git is connected.

- If the device's main address doesn't answer, Git tries its other addresses, such as its local network name or its
  Hub address.
- If the project is on several devices, Git tries each in turn and opens the first that answers.
- While the repository is open, Git checks for changes every few seconds. When you leave it, the connection closes.

### The first connection

The first time Git connects to a machine, it asks **Trust this server's key?** and shows the key's fingerprint.
Nothing is sent before you answer. **Trust and Connect** remembers the key in your vault. If the key changes later,
Git refuses to connect. A clone from one of your vault's SSH hosts, at one of its addresses, doesn't ask again when the
server shows the key the vault already trusts for that host.

### Face ID or Touch ID

This device's key may ask you to confirm with Face ID, Touch ID or your passcode before it signs in. A yes lasts 15
minutes in Git. If you decline, the sign-in fails. See
[Privacy and Security](Privacy-and-Security.md#this-devices-key).

### When it can't connect

Git shows **Couldn’t Open …** with each device's error, and what the device last reported. Wake the Mac or turn on
Remote Login, then tap **Try Again**. Common messages:

- *… has no user name to sign in as. Set one in the Vault app.*: give the host a user name in Vault.
- *… signs in with a key another app imported. Use this device’s key instead.*

## How current the list is

A row under **On Your Devices** shows what its device last wrote to your vault, and how long ago (**as of 2 hr. ago**).
A device writes it when the repository changes there while Git runs. Pull down on the list to ask the devices again:
see [Repositories](Repositories.md#the-repository-list-on-iphone-and-ipad).

## Several repositories at once

A group's menu under **On Your Devices** has **Fetch All**, **Pull All** and **Push All**. They run on the devices,
each repository over its own connection.

## On the Mac

Repositories on your other devices are listed in the Mac's sidebar too, under **On Your Devices** (or **On Other
Machines**). Click one to open it over SSH.

When Git starts, it doesn't connect to another device by itself. If the last session ended on such a repository, Git
shows its name, where it is and what the device last reported, with a **Connect** button. Click **Connect**, or pick it
again in the sidebar.

## Security levels

The **Settings ▸ Security** level applies here too:

- At **SSH only**, an orange banner says **SSH only isn’t enforced here**: the other device's git uses its own keys and
  setup.
- At **Vault key only**, the banner says **Fetch, pull and push are off here**, and **Sync** is off for repositories on
  other devices.

See [Privacy and Security](Privacy-and-Security.md#security-levels).
