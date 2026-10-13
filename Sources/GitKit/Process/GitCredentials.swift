import Foundation
import os

/// A username and password (or token) for one HTTPS host.
public struct GitCredential: Sendable, Hashable {
  public var username: String
  public var password: String

  public init(username: String, password: String) {
    self.username = username
    self.password = password
  }
}

/// Credentials the app hands git for HTTPS hosts, in place of the user's credential helpers.
///
/// Fetch, pull, push and clone run with one credential helper per host that answers from the
/// process environment. The helpers configured for that host before it (osxkeychain, gh, …) are
/// cleared, so git neither reads the user's stored credential nor saves the app's token anywhere.
/// The token reaches git only through that one process's environment, never its arguments, which
/// other users can read with `ps`.
public enum GitCredentials {
  private static let store = OSAllocatedUnfairLock<[String: GitCredential]>(initialState: [:])

  /// Sets the credential for `host` (e.g. `github.com`), or removes it with `nil`.
  public static func set(_ credential: GitCredential?, for host: String) {
    store.withLock { $0[host.lowercased()] = credential }
  }

  public static func credential(for host: String) -> GitCredential? {
    store.withLock { $0[host.lowercased()] }
  }

  /// The environment for a network command: config entries in `GIT_CONFIG_COUNT` form, which
  /// git reads after every config file, and the credentials themselves. Empty without
  /// credentials.
  static func environment() -> [String: String] {
    let credentials = store.withLock { $0 }.sorted { $0.key < $1.key }
    guard !credentials.isEmpty else { return [:] }
    var environment: [String: String] = [:]
    var count = 0
    func config(_ key: String, _ value: String) {
      environment["GIT_CONFIG_KEY_\(count)"] = key
      environment["GIT_CONFIG_VALUE_\(count)"] = value
      count += 1
    }
    for (index, (host, credential)) in credentials.enumerated() {
      let key = "credential.https://\(host).helper"
      // An empty helper clears the ones configured so far.
      config(key, "")
      // Answers `get` only; `store` and `erase` have nothing to keep. git appends the action.
      config(
        key,
        "!f() { cat >/dev/null; test \"$1\" = get || exit 0; "
          + "echo \"username=$GITKIT_USERNAME_\(index)\"; "
          + "echo \"password=$GITKIT_PASSWORD_\(index)\"; }; f")
      environment["GITKIT_USERNAME_\(index)"] = credential.username
      environment["GITKIT_PASSWORD_\(index)"] = credential.password
    }
    environment["GIT_CONFIG_COUNT"] = String(count)
    return environment
  }
}
