# Repositories

## The repository list on the Mac

The **Repositories** section of the sidebar shows every repository you added, with its state before you open it:

- an orange dot with the number of changed files,
- ↑ with the number of commits to push, and ↓ with the number to pull,
- a merge or rebase in progress, and a branch that isn't published yet.

One file watcher covers all of them, so the list stays current. A group's header adds up the state of its
repositories. When you collapse the section, it still shows the open repository, and its header shows an icon for each
other repository that needs attention.

### Add repositories

- Click **Add Repository** (+) in the section's header and choose **From Directory…**, **Clone…** or **Create New…**.
- Or use the **File** menu: **Clone Repository…** (⇧⌘C), **New Repository…** (⌥⌘N), **Open Repository…** (⌘O) and
  **Add Folder…** (⇧⌘O).
- Or drop a folder on the sidebar. Every Git repository inside it is added. A folder without one asks whether to
  **Create Repository** there.

### Groups

Repositories that share a folder become a group named after that folder, with the folder above it as a note. Groups
can hold groups.

- **Reorder:** drag repositories and groups. Drop onto the middle of a group's header to move them into it. A closed
  group opens if you hold it there.
- **Group a repository:** right-click it and choose **Group ▸ New Group…**, or pick an existing group. **Group ▸
  Remove from Group** takes it out.
- **A group's menu** has **Rename…**, **Ungroup** (the repositories stay in the list), **Move to Group**,
  **Move Out of Group**, **Hide Group** and **Remove Group from List**. It also opens the group's folder in Code,
  Finder or Terminal.

Groups live in your vault's project list, so the other v57 apps and your other Macs see the same groups. Which groups
are collapsed is Git's own.

### Work with several repositories at once

⌘-click or ⇧-click to select several repositories. Their menu fetches, pulls, pushes, hides or removes them together,
and dragging one of them moves them all. A group's menu has **Fetch All**, **Pull All** and **Push All**. **Push All**
leaves out repositories with nothing to push.

### A repository's menu

Right-click a repository for:

- **Fetch**, **Pull** and **Push**, with a preview of what each would do.
- Open it in **Xcode** (when it holds a project or a Swift package), **Code**, **Finder** or **Terminal**.
- **Group**, to move it into a group.
- **On Other Devices ▸ Copy SSH Command for …**, which copies a command that opens a terminal in this repository's
  folder on another of your devices.
- **Hide** and **Remove from List**. Removing takes it off the list only. Its folder stays on disk.

### Sort and filter

The **Repositories** header menu has:

- **All Repositories**: every repository as a card (**Grid**) or row (**List**), with its branch, last commit, changes,
  and commits to push and pull. It has **Fetch All** for every repository shown, **Clone**, and a search field.
- **Sort By**: **Name**, **Recent Changes**, **Last Commit** or **Last Push**. A date order turns off **Group by
  Folder**. This changes the order of the list only.
- **Show the Project**: where the open repository's sections go: **Project Below the List**, **Project Below, List
  Folded** or **Project Inside the List**.
- **Hide Unused for a Week**, **Only With Changes** and **Group by Folder**.
- **Show N Hidden** and **Hide Hidden Repositories**, for repositories you hid.
- **Remove All Repositories from List**: the folders stay on disk.
- **Remove All Projects…**: removes the projects from your vault, so they leave Code, Dev, Markdown and the other v57
  apps on this Mac. Their folders stay on disk.

The sidebar's **Filter** field filters the list and the open repository's branches and tags.

### Accounts

Each Git window belongs to one vault account: your personal one, or one you work for. The account picker at the top of
the sidebar switches the window's account, opens an account in a new window, or manages accounts in
**Settings ▸ Accounts**. Each account has its own repositories and its own GitHub sign-in.

## The repository list on iPhone and iPad

The sidebar has up to three sections:

- **On This iPhone** (or **On This iPad**): repositories stored on the device, with the subtitle **Files › Git**. The
  **+** menu has **Clone Repository…**, **New Repository…** and **Try a Sample Repository** (see
  [Getting Started](Getting-Started.md#try-a-sample-repository)).
- **On Your Devices**: your vault's projects that live on another device you can sign in to, in their groups. It
  starts folded. Each row shows its branch, how old its marks are (**as of 2 hr. ago**), the devices it's on, and the
  changes, ↑ and ↓ that device last saw. See [Repositories on Other Devices](Other-Devices.md).
- **Opened on a Mac**: folders you opened with **Open on a Mac**. Touch and hold a row and choose **Remove from List**
  to take it off. The folder stays on the Mac.

Type in **Search Repositories** to filter all three sections.

Pull down on the list to refresh it. Git asks each device in **On Your Devices** how its repositories are now, over
SSH and a few at a time, without fetching. A repository whose device doesn't answer keeps the marks that device last
wrote, with their age, and a **Couldn’t refresh …** notice says why. Repositories that failed for the same reason share
one line. At **Vault key only**, the refresh can't reach them, and the notice says so.

### Groups of On Your Devices

Tap a group to open or close it. Touch and hold it for:

- **Fetch All**, **Pull All** and **Push All**: they run on that device, a few repositories at a time, and show a
  notice for each one that fails.
- **Rename…**, **Ungroup**, **Move to Group** and **Move Out of Group**: these change the shared project list in every
  v57 app.
- **Hide Group** and **Remove Group from List**: these change this device's list only.

The **On Your Devices** header menu has **Sort By** (**As Arranged**, **Name**, **Recently Added**, and, when your
devices have reported status, **With Changes First**, **Last Commit** and **Last Push**), **Show N Hidden** and
**Restore N Removed**.

### Delete a repository from the device

Touch and hold a repository under **On This iPhone** and choose **Delete…**. Its folder is deleted from the device,
with any commits you never pushed.
