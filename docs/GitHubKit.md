# GitHubKit

## Purpose

GitHubKit signs an app in to GitHub and makes the REST and GraphQL calls the v57 apps need: the user and their
organizations, creating a repository (Publish), the Git Data API (download a branch and commit to it without git),
and releases, issues and Discussions. `GitHubAccount` is an observable account for a UI, and `KeychainTokenStore`
keeps the token so one sign-in serves every v57 app on the user's devices. Git, Markdown, Dev and Community use it.

GitHubKit has no UI (the sign-in sheet is [GitHubUI](GitHubUI.md)) and does not depend on [GitKit](GitKit.md). It
covers only the calls listed below, not the whole GitHub API.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Git.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "GitHubKit", package: "Git")]),
]
```

GitHubKit depends on VaultKit (`https://github.com/v57/Vault.git`), which SwiftPM fetches with it. With `V57_LOCAL=1`
in the environment, the package takes Vault and Component from checkouts next to this one.

You need a GitHub OAuth App with device flow turned on. Only its public client ID goes into the app: the device flow
needs no client secret.

```swift
import GitHubKit

@MainActor
func signIn() -> GitHubAccount {
  let account = GitHubAccount(
    clientID: "<your OAuth App's client ID>",
    store: KeychainTokenStore(service: "com.example.MyApp.github"))
  account.restore(refreshing: false)  // the saved sign-in, without contacting GitHub
  if !account.isSignedIn {
    account.signIn(requesting: .recommended) { code in
      print("Enter \(code.userCode) at \(code.verificationURL)")
    }
  }
  return account
}
```

`signInStep` moves through `.requestingCode`, `.waiting(DeviceCode)` and `.succeeded` or `.failed`. Once signed in,
`account.api` is a `GitHubAPI` with the token:

```swift
if let api = account.api {
  let repository = try await api.createRepository(NewRepository(name: "MyApp", isPrivate: true))
  print(repository.cloneURL)
}
```

## Main API

### Signing in

- `GitHubAccount(clientID:store:transport:)`: `@MainActor @Observable`. `user`, `organizations`, `credential`,
  `permissions`, `isSignedIn`, `signInStep`, `notice` (why it signed out on its own), `api`.
  - `restore(refreshing:)` loads the saved credential. With `refreshing: true` it also reloads the profile in the
    background. Pass `false` if your app contacts GitHub only when the user asks.
  - `refresh()` reloads the profile, organizations and granted scopes. A revoked token (HTTP 401) signs out and sets
    `notice`.
  - `signIn(requesting:onCode:)` starts the device flow. The current sign-in keeps working until the new token
    arrives, so changing permissions and then cancelling leaves the old ones.
  - `signIn(with:)` uses a credential another sign-in already has, without the device flow.
  - `cancelSignIn()`, `endSignIn()` (clear a finished result once shown) and `signOut()` (forgets the token; GitHub
    keeps the authorization until the user revokes it on github.com).
  - `onCredentialChange`: called whenever the credential changes, for example to hand the token to GitKit's
    `GitCredentials`.
- `DeviceFlow(clientID:transport:)` with `start(scopes:)` and `token(for:)`: the OAuth device flow (RFC 8628) on its
  own, if you don't want `GitHubAccount`. It polls at GitHub's interval and slows down when asked.
- `DeviceCode` (`userCode`, `verificationURL`, `expiresAt`, `interval`) and `DeviceGrant` (`token`, `scopes`).
- `GitHubPermissions(repositories:organizations:workflows:)`: what to ask for and what was granted, as OAuth scopes
  (`repo` or `public_repo`, `read:org`, `workflow`). `.recommended`, `.none`, `init(scopes:)`, `scopes`,
  `includes(_:)`, `union(_:)`. GitHub may grant fewer scopes than requested; `permissions` shows what it granted.

### Keeping the token

- `TokenStore`: `load()`, `save(_:)`, `delete()` of a `GitHubCredential` (`login`, `token`, `scopes`,
  `permissions`).
- `KeychainTokenStore(service:accessGroup:)`: one generic-password item on Apple platforms.
  - Without an access group the item is in the login keychain, and only the app's code signature may read it without a
    prompt.
  - With an access group the item is in the data-protection keychain, shared by the team's apps that list the group,
    and synced through iCloud Keychain. A build that isn't entitled to the group keeps its own item.
  - While the user has turned iCloud off for the v57 apps (VaultKit's `VaultICloud`), a new sign-in stays on this
    device and goes to iCloud Keychain when iCloud is on again. Signing out deletes both copies.
  - `KeychainTokenStore.shared` is the v57 apps' shared sign-in. `forAccount(_:)` gives each vault account its own
    item next to it (`personalAccountID` maps to `shared`), and `signIns(of:)` lists the accounts that are signed in,
    one per login.
- `MemoryTokenStore`: keeps the credential in memory, for tests and previews.

### REST and GraphQL calls

`GitHubAPI(token:transport:)`. Without a token, calls are anonymous: public repositories only, and GitHub's lower rate
limit.

- User: `user()`, `userAndScopes()` (with the token's scopes from `X-OAuth-Scopes`), `organizations()` (the first 100).
- Repositories: `repositories(limit:)` (most recently updated first), `repository(owner:name:)`, `isEmpty(owner:name:)`,
  `createRepository(_:)` with a `NewRepository` (for the user or an organization), `createOrAdoptRepository(_:owner:)`
  (takes over an empty repository of the same name, refuses one with commits), `updateRepository(owner:name:description:isPrivate:)`.
  `NewRepository.normalizedName(_:)` turns a name into the one GitHub would create.
- Git Data: `head(owner:name:branch:)`, `tree(owner:name:commit:)`, `files(owner:name:tree:)` (every file, recursively),
  `blob(owner:name:sha:)`, `createBlob(owner:name:content:)`, `createTree(owner:name:base:changes:)` with
  `GitHubTreeChange` (a `nil` sha deletes the file), `createCommit(owner:name:message:tree:parent:)`,
  `updateBranch(owner:name:branch:to:)` (never forced: GitHub refuses a commit that doesn't descend from the branch).
  `GitHubAPI.blobSHA(_:)` computes git's blob id locally, so unchanged files can be skipped without asking GitHub.
- Releases: `createRelease(owner:repository:tag:name:body:draft:prerelease:target:generateNotes:)`,
  `release(owner:repository:tag:)` (`nil` when there is none), `updateRelease(owner:repository:id:name:body:)`,
  `uploadReleaseAsset(owner:repository:releaseID:name:data:contentType:)`, `deleteReleaseAsset(owner:repository:id:)`.
- Issues and Discussions: `createIssue(owner:repository:title:body:labels:)`,
  `discussionCategories(owner:repository:)` (the repository's GraphQL id and its categories),
  `createDiscussion(repositoryID:categoryID:title:body:)`.

Models: `GitHubUser`, `GitHubOrganization`, `GitHubRepository` (`fullName`, `owner`, `cloneURL`, `sshURL`,
`defaultBranch`, …), `GitHubTreeEntry`, `GitHubRelease`, `GitHubReleaseAsset`, `GitHubIssue`,
`GitHubDiscussionCategory`, `GitHubDiscussion`.

A commit through the Git Data API:

```swift
let api = GitHubAPI(token: token)
let head = try await api.head(owner: "user", name: "notes", branch: "main")
let base = try await api.tree(owner: "user", name: "notes", commit: head)
let blob = try await api.createBlob(owner: "user", name: "notes", content: Data("# Notes\n".utf8))
let tree = try await api.createTree(
  owner: "user", name: "notes", base: base, changes: [GitHubTreeChange(path: "README.md", sha: blob)])
let commit = try await api.createCommit(owner: "user", name: "notes", message: "Update README", tree: tree, parent: head)
try await api.updateBranch(owner: "user", name: "notes", branch: "main", to: commit)
```

### Errors and transport

- `GitHubError`: `.unauthorized`, `.signInDeclined`, `.codeExpired`, `.api(status:message:)` (GitHub's most specific
  message, as a sentence), `.signIn(_:)`, `.invalidResponse`. Each has an `errorDescription` to show as it is.
- `HTTPTransport`: `send(_:)` of a `URLRequest`. `URLSession` conforms; pass a fake in tests. Every request carries
  the app's bundle identifier and version as its User-Agent.

## Platform notes

- **macOS** (14 and later) and **iOS and iPadOS** (17 and later): everything. The token is in the keychain as above.
- **Linux and Windows:** builds, on v57/SwiftUI's `CryptoKit` stand-in and FoundationNetworking. `KeychainTokenStore`
  keeps the credential with VaultKit's `VaultKeychain` (on Windows, the Credential Manager), on this device only; the
  access group and iCloud do nothing there. Git's Linux and Windows app uses it; the device flow there is not
  separately tested.
- **Android:** not yet.

## Testing

```bash
swift test --filter GitHubKitTests
```

The tests answer requests with a fake `HTTPTransport` and never contact GitHub: the device flow (approved and
declined), creating and adopting repositories, error messages, permissions, the account's sign-in, and the Git Data
calls. In your own tests, give `GitHubAccount` or `GitHubAPI` your own `HTTPTransport` and a `MemoryTokenStore`.

After changing GitHubKit, check that it still builds for iOS:

```bash
swift build --target GitHubKit --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
```

See also: [GitHubUI](GitHubUI.md) for the sign-in sheet, and the user guide's
[Fetch, Pull, Push and GitHub](Syncing-and-GitHub.md) and [Privacy and Security](Privacy-and-Security.md).
