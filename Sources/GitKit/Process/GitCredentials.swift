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
/// other users can read with `ps`. On another machine it gets there over the command's stdin
/// (`shellSecrets`), since the command's text is an argument too.
///
/// Each account (an app's sign-in, e.g. a vault account's GitHub sign-in) has its own credentials;
/// `nil` is the default one. A repository uses its runner's `credentialAccount`, so two windows
/// signed in to different accounts push with their own tokens.
public enum GitCredentials {
  private struct Key: Hashable {
    var account: String?
    var host: String
  }

  private static let store = OSAllocatedUnfairLock<[Key: GitCredential]>(initialState: [:])

  /// Sets the credential for `host` (e.g. `github.com`) in `account`, or removes it with `nil`.
  public static func set(_ credential: GitCredential?, for host: String, account: String? = nil) {
    store.withLock { $0[Key(account: account, host: host.lowercased())] = credential }
  }

  public static func credential(for host: String, account: String? = nil) -> GitCredential? {
    store.withLock { $0[Key(account: account, host: host.lowercased())] }
  }

  /// The environment for a network command with `account`'s credentials: config entries in
  /// `GIT_CONFIG_COUNT` form, which git reads after every config file, and the credentials
  /// themselves. Empty without credentials, so git uses the user's own helpers. `hosts` limits it to
  /// those hosts' credentials.
  static func environment(account: String? = nil, hosts: Set<String>? = nil) -> [String: String] {
    let credentials = store.withLock { store in
      store.compactMap { key, value in
        key.account == account && hosts?.contains(key.host) != false ? (key.host, value) : nil
      }
    }.sorted { $0.0 < $1.0 }
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

  /// The host credentials are kept under for a remote's URL; nil unless it's HTTPS, the only way they're used.
  static func host(ofRemote url: String) -> String? {
    guard let components = URLComponents(string: url), components.scheme?.lowercased() == "https" else { return nil }
    return components.host?.lowercased()
  }

  /// Whether an entry of `environment(account:)` is a username or password.
  public static func isSecret(_ name: String) -> Bool {
    name.hasPrefix("GITKIT_USERNAME_") || name.hasPrefix("GITKIT_PASSWORD_")
  }

  /// For a command given to a shell as text: the start of a script that reads `environment`'s
  /// secrets from stdin and exports them, and the lines to send it. A shell's `read` takes no more
  /// than its line, so what follows on stdin stays for the command.
  public static func shellSecrets(in environment: [String: String]) -> (script: String, input: Data) {
    let names = environment.keys.filter(isSecret).sorted()
    let script = names.map { "IFS= read -r \($0); export \($0); " }.joined()
    return (script, Data(names.map { environment[$0]! + "\n" }.joined().utf8))
  }
}
