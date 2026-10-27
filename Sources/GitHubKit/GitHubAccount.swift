import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import Observation

/// The app's GitHub account for a UI: signs in with the device flow for the permissions the user
/// picked, keeps the token and its granted scopes in a `TokenStore`, and loads the user and their
/// organizations.
///
/// A sign-in runs beside the current account: while the user changes permissions, the old token
/// keeps working until the new one arrives.
@MainActor @Observable
public final class GitHubAccount {
  /// Where a running or just-finished sign-in is.
  public enum SignInStep: Sendable, Hashable {
    /// Asking GitHub for a code.
    case requestingCode
    /// Waiting for the user to enter the code on github.com.
    case waiting(DeviceCode)
    /// Signed in. `requested` is what the user asked for; `permissions` has what was granted.
    case succeeded(requested: GitHubPermissions)
    case failed(GitHubError)
  }

  /// The signed-in user. Only `login` is known until the profile loads.
  public private(set) var user: GitHubUser?
  public private(set) var organizations: [GitHubOrganization] = []
  /// The current sign-in, until `endSignIn()`; `nil` when none is shown.
  public private(set) var signInStep: SignInStep?
  /// Why the account was signed out on its own (a revoked token), for Settings.
  public var notice: String?

  /// The token, login and granted scopes, or `nil` when signed out.
  public private(set) var credential: GitHubCredential? {
    didSet { if credential != oldValue { onCredentialChange?(credential) } }
  }
  /// Called whenever `credential` changes, to hand it to git.
  public var onCredentialChange: ((GitHubCredential?) -> Void)?

  private let flow: DeviceFlow
  private let store: any TokenStore
  private let transport: any HTTPTransport
  private var signInTask: Task<Void, Never>?

  public init(clientID: String, store: any TokenStore, transport: any HTTPTransport = URLSession.shared) {
    flow = DeviceFlow(clientID: clientID, transport: transport)
    self.store = store
    self.transport = transport
  }

  public var isSignedIn: Bool { credential != nil }

  /// What GitHub granted; `.none` when signed out.
  public var permissions: GitHubPermissions { credential?.permissions ?? .none }

  /// The API as the signed-in user.
  public var api: GitHubAPI? {
    credential.map { GitHubAPI(token: $0.token, transport: transport) }
  }

  /// Loads the saved credential, then (with `refreshing`) refreshes the profile in the
  /// background. Git can use the credential right away, before the profile loads or without a
  /// network. Apps that contact GitHub only when the user asks pass `refreshing: false`.
  public func restore(refreshing: Bool = true) {
    guard let saved = try? store.load() else { return }
    credential = saved
    user = GitHubUser(login: saved.login)
    if refreshing { Task { await refresh() } }
  }

  /// Reloads the profile, organizations and granted scopes. A revoked token signs out.
  public func refresh() async {
    guard let api, let credential else { return }
    do {
      async let profile = api.userAndScopes()
      // Without read:org GitHub lists only public memberships.
      async let organizations = api.organizations()
      let (user, scopes) = try await profile
      self.user = user
      if let scopes, scopes != credential.scopes, self.credential?.token == credential.token {
        // The user changed the authorization on github.com.
        var updated = credential
        updated.scopes = scopes
        try? store.save(updated)
        self.credential = updated
      }
      self.organizations = (try? await organizations) ?? self.organizations
    } catch GitHubError.unauthorized {
      signOut()
      notice = GitHubError.unauthorized.errorDescription
    } catch {
      // Offline or GitHub is down: keep what is known.
    }
  }

  /// Starts the device flow for `permissions`. `signInStep` becomes `.waiting` with the code to
  /// show, and `onCode` gets it as soon as it arrives, to open the page where the user enters it.
  public func signIn(requesting permissions: GitHubPermissions, onCode: ((DeviceCode) -> Void)? = nil) {
    signInTask?.cancel()
    notice = nil
    signInStep = .requestingCode
    signInTask = Task {
      do {
        let code = try await flow.start(scopes: permissions.scopes)
        signInStep = .waiting(code)
        onCode?(code)
        let grant = try await flow.token(for: code)
        let api = GitHubAPI(token: grant.token, transport: transport)
        let (user, header) = try await api.userAndScopes()
        let credential = GitHubCredential(login: user.login, token: grant.token, scopes: header ?? grant.scopes)
        try store.save(credential)
        if user.login != self.user?.login { organizations = [] }
        self.user = user
        self.credential = credential
        signInStep = .succeeded(requested: permissions)
        signInTask = nil
        await refresh()
      } catch {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        signInStep = .failed(error as? GitHubError ?? .signIn(error.localizedDescription))
        signInTask = nil
      }
    }
  }

  /// Signs in with a credential another sign-in already has (another vault account's), without the device flow.
  /// It is saved in this account's store, so each keeps its own copy and signing out here leaves the other signed
  /// in. Only `login` is known until `refresh()`.
  public func signIn(with credential: GitHubCredential) throws {
    cancelSignIn()
    try store.save(credential)
    notice = nil
    if credential.login != user?.login { organizations = [] }
    user = GitHubUser(login: credential.login)
    self.credential = credential
  }

  /// Stops a running sign-in. The account stays as it was.
  public func cancelSignIn() {
    signInTask?.cancel()
    signInTask = nil
    signInStep = nil
  }

  /// Clears a finished sign-in's result once the UI has shown it.
  public func endSignIn() {
    if signInTask == nil { signInStep = nil }
  }

  /// Forgets the token. GitHub keeps the authorization until the user revokes it in
  /// Settings › Applications, which needs the client secret to do from here.
  public func signOut() {
    cancelSignIn()
    try? store.delete()
    credential = nil
    user = nil
    organizations = []
  }
}
