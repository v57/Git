#if DEBUG
  import Foundation
  import SSHKit

  /// Debug builds take repositories on another machine from the launch environment, for trying either app against a
  /// test host (the simulator has no Secure Enclave key and no Hub; a scripted Mac run keeps the user's vault out):
  ///
  /// `GIT_DEBUG_REMOTE`: `{"name", "host", "port", "user", "directory", "key"}` (or an array of them): a repository on
  /// another machine, `key` a private key file the server accepts (or `keyText`, its contents), `device` the device's
  /// name in the app, `group` a vault group to show it in (the iPhone and iPad app makes it a vault project there).
  ///
  ///     SIMCTL_CHILD_GIT_DEBUG_REMOTE='{…}' xcrun simctl launch <udid> dev.v57.git
  ///     GIT_DEBUG_REMOTE='{…}' open -g -n Git.app --args --in-memory
  @MainActor public enum DebugRemotes {
    public struct Remote: Decodable, Sendable {
      public var name: String
      public var host: String
      public var port: Int?
      public var user: String
      public var directory: String
      public var key: String?
      public var keyText: String?
      public var device: String?
      public var group: String?
    }

    public static let remotes: [Remote] = ProcessInfo.processInfo.environment["GIT_DEBUG_REMOTE"].flatMap { json in
      let data = Data(json.utf8)
      return (try? JSONDecoder().decode([Remote].self, from: data))
        ?? (try? JSONDecoder().decode(Remote.self, from: data)).map { [$0] }
    } ?? []

    /// The id of the repository `remote` becomes (`RemoteRepository.id`), which a vault project of a `group` takes too.
    public static func id(of remote: Remote) -> String { "debug-" + remote.name }

    public static var repositories: [RemoteRepository] {
      remotes.enumerated().map { index, remote in
        let target = RemoteTarget(
          id: "debug-\(index)", name: remote.device ?? remote.host, host: remote.host, port: remote.port ?? 22,
          user: remote.user, directory: remote.directory, detail: remote.device == nil ? "debug" : "via Hub")
        return RemoteRepository(id: id(of: remote), name: remote.name, targets: [target])
      }
    }

    /// The login of a debug remote's target: its key, never this device's.
    public static func login(for target: RemoteTarget) -> SSHServer? {
      guard target.id.hasPrefix("debug-"), let index = Int(target.id.dropFirst(6)), remotes.indices.contains(index)
      else { return nil }
      let remote = remotes[index]
      let text = remote.keyText ?? remote.key.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
      return SSHServer(host: target.host, port: target.port, user: remote.user, key: try? SSHKey(importing: text))
    }
  }
#endif
