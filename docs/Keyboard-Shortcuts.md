# Keyboard Shortcuts

Every menu command with a shortcut, and the keys that work in Git's lists, diffs and sheets. Menus show the same keys
next to each command.

## On the Mac

<!-- only: linux windows -->
On Linux and Windows, the menus are in the window, and every shortcut written with ⌘ here uses Ctrl instead: Ctrl+1
for Changes, Ctrl+Shift+F for Fetch. ⇧ is Shift and ⌥ is Alt.
<!-- /only -->

### File menu

| Command | Keys |
|---|---|
| **Clone Repository…** | ⇧⌘C |
| **New Repository…** | ⌥⌘N |
| **Open Repository…** | ⌘O |
| **Add Folder…** | ⇧⌘O |

The welcome screen's **Clone Repository…**, **Open Local Repository…** and **New Repository…** take the same keys.

### View menu

| Command | Keys |
|---|---|
| **Changes** | ⌘1 |
| **History** | ⌘2 |
| **Stashes** | ⌘3 |
| **Hide Whitespace Changes** | (no shortcut) |

### Repository menu

| Command | Keys |
|---|---|
| **Refresh** | ⌘R |
| **Fetch** | ⇧⌘F |
| **Pull** | ⇧⌘P |
| **Push**, or **Publish to GitHub…** in a repository with no remote | ⌘P |
| **Stage All** | ⇧⌘A |
| **Unstage All** | (no shortcut) |
| **Show in Finder** (**Show in Files** on Linux, **Show in Explorer** on Windows) | (no shortcut) |
| **Open in Terminal** | (no shortcut) |

### Committing

| Action | Keys |
|---|---|
| **Commit N Files** | ⌘↩ |
| **Commit & Push** | ⇧⌘↩ |
| Take the suggested summary (in the empty summary field) | Tab |
| Move from the summary to the description | ↩ |

### Diffs

| Action | Keys |
|---|---|
| Select a range of lines | ⇧-click |
| Copy the selected lines | ⌘C |

### History

| Action | Keys |
|---|---|
| Select the next or previous commit | ↓ or ↑ |
| Extend the selection | ⇧↓ or ⇧↑ |
| **Squash** in the Squash sheet | ⌘↩ |

### Resolve Conflicts

| Action | Keys |
|---|---|
| **Use Current for Next Conflict** | ⌥⌘← |
| **Use Incoming for Next Conflict** | ⌥⌘→ |

### Repository list

| Action | Keys |
|---|---|
| Select several repositories | ⌘-click or ⇧-click |

### Sheets

In every sheet, Esc cancels and Return runs the main button. In sheets with a description field, such as Squash, Return
starts a new line and ⌘↩ runs the main button. In **New Branch**, Tab in the empty name field fills in
`feature/my-change`.

## On iPhone and iPad

With a hardware keyboard:

- In **Clone Repository**, **New Repository**, **Open on a Mac**, **New Branch** and the GitHub sign-in sheet, Esc
  cancels and Return runs the main button.
- In the commit box, Return starts a new line. It doesn't commit.
