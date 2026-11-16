# GitHubUI

## Purpose

GitHubUI is the GitHub sign-in sheet the v57 apps share, built on ComponentKit. The user picks what the app may do
(public and private or only public repositories, organizations, workflow files), enters the code on github.com, and
sees what GitHub granted. The same sheet changes the permissions of an existing sign-in. Git, Markdown and Community
show it.

It is a thin layer over [GitHubKit](GitHubKit.md)'s `GitHubAccount`: it holds no token and makes no request of its
own. Settings screens (the account, its permissions, sign out) stay in each app.

## Platforms

<!-- platforms: macos ios linux windows -->

- **macOS** (14 and later) and **iOS and iPadOS** (17 and later): the sheet is 540 points wide, and as wide as the
  screen on a phone, where its choices and buttons stack.
- **Linux and Windows:** builds on v57/SwiftUI as part of Git's desktop app there. Not tested on its own.
- **Android:** not yet.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Git.git", branch: "main"),
  .package(url: "https://github.com/v57/Component.git", branch: "main"),
],
targets: [
  .target(
    name: "MyApp",
    dependencies: [
      .product(name: "GitHubKit", package: "Git"), .product(name: "GitHubUI", package: "Git"),
      .product(name: "ComponentKit", package: "Component"),
    ]),
]
```

GitHubUI depends on ComponentKit, which SwiftPM fetches with it; the Component package is listed above because the
example imports ComponentKit itself (for `kitSheet(item:)`). With `V57_LOCAL=1`, the package takes Component and Vault
from checkouts next to this one.

Present the sheet with ComponentKit's `kitSheet(item:)`. It closes itself.

```swift
import ComponentKit
import GitHubKit
import GitHubUI
import SwiftUI

struct GitHubButton: View {
  let account: GitHubAccount
  @State private var request: GitHubSignInRequest?

  var body: some View {
    Button(account.isSignedIn ? "Change Permissions…" : "Sign In to GitHub…") {
      request = GitHubSignInRequest(permissions: account.isSignedIn ? account.permissions : .recommended)
    }
    .kitSheet(item: $request) { request in
      GitHubSignInSheet(
        account: account, appName: "MyApp", permissions: request.permissions, systemImage: "doc.text")
    }
  }
}
```

## Main API

### The sign-in sheet

- `GitHubSignInSheet(account:appName:permissions:choices:offers:use:glyph:)`: the sheet, with your app's glyph as a
  trailing `@ViewBuilder` closure.
  - `appName` is how the text names your app ("Choose what MyApp can do with your account").
  - `permissions` is what the chooser starts with.
  - `choices` are the switches under the repositories' choice, `[.organizations, .workflows]` by default. Pass `[]`
    for an app that needs repositories only.
  - `offers` returns other vault accounts' sign-ins to offer while this account has none; the one the user picks goes
    to `use`, which should sign `account` in with it (`GitHubAccount.signIn(with:)`).
  - `glyph` is your app's glyph on its accent tile. `init(…systemImage:)` takes an SF Symbol name instead.
  - Continue starts the device flow, copies the code and opens github.com's page to enter it (through ComponentKit's
    `KitPasteboard` and `KitDesktop`). Closing the sheet while it waits cancels the sign-in.
- `GitHubSignInRequest(permissions:)`: an `Identifiable` item for `kitSheet(item:)`.

A repositories-only app with its own glyph:

```swift
.kitSheet(item: $request) { request in
  GitHubSignInSheet(
    account: account, appName: "MyApp", permissions: request.permissions, choices: []
  ) {
    Image(systemName: "doc.text")
  }
}
```

### Offering another account's sign-in

`GitHubSignInOffer(accountName:credential:)` is a sign-in another vault account has; the sheet lists them through
`offers`. `GitHubSignInOfferRow(offer:use:)` shows one as a row of a ComponentKit `FormCard`, for your own screens.

```swift
GitHubSignInSheet(
  account: account, appName: "MyApp", permissions: .recommended,
  offers: {
    KeychainTokenStore.signIns(of: otherAccountIDs).map {
      GitHubSignInOffer(accountName: name(of: $0.accountID), credential: $0.credential)
    }
  },
  use: { offer in try? account.signIn(with: offer.credential) },
  systemImage: "doc.text")
```

`otherAccountIDs` and `name(of:)` stand for your app's vault accounts and their names.

### Pieces for a settings screen

- `GitHubPermission`: `.privateRepositories`, `.organizations`, `.workflows`, with `title`, `scope`, `detail`,
  `permissions` and `isGranted(in:)`, for a settings screen that lists them.
- `ScopeLabel(scope:)`: an OAuth scope name in GitHub's style.
- `URL.gitHubAvatar(size:)`: an avatar URL that asks GitHub for the image at twice `size`, for ComponentKit's
  `Avatar(name:url:size:)`.
- `GitHubConnectionView(phase:tileSize:glyph:)` (or `systemImage:`) with `GitHubConnectionPhase` (`.idle`, `.waiting`,
  `.connected`, `.failed`): the animated header of the sheet, the app's tile joined to GitHub's.

```swift
FormCard("GitHub") {
  ForEach(GitHubPermission.allCases) { permission in
    HStack {
      Text(permission.title)
      ScopeLabel(scope: permission.scope)
      Spacer()
      Image(systemName: permission.isGranted(in: account.permissions) ? "checkmark" : "xmark")
    }
  }
}
```

## Testing

GitHubUI has no tests of its own. Its logic lives in GitHubKit (`swift test --filter GitHubKitTests`). To see the
sheet, give it a `GitHubAccount` with a `MemoryTokenStore`. In Git's Debug builds, `--github-sign-in` opens it over the
selected repository at launch.

## Related

- [GitHubKit](GitHubKit.md): `GitHubAccount`, the token stores and `GitHubPermissions`, which the sheet works on.
- [ComponentKit](https://github.com/v57/Component/blob/main/docs/ComponentKit.md): the sheet's controls,
  `kitSheet(item:)` and `FormCard`.
- The user guide's [Fetch, Pull, Push and GitHub](Syncing-and-GitHub.md).
