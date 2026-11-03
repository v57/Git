import Foundation
import os

/// How far network actions (clone, fetch, pull, push) may go on this device: Settings ▸ Security, kept in the vault so
/// all the user's devices follow one rule. Status, commit, merge and rebase run `git` at every level: they never see
/// a key or a token.
public enum GitSecurityLevel: Int, Sendable, CaseIterable, Identifiable {
  /// The `git` command with the user's own setup, plus the app's token in its environment.
  case useGit = 1
  /// In the app with the vault's key or the token; else `git` with the user's own keys and helpers, never the token.
  case inAppFirst = 2
  /// In the app; HTTPS remotes move to SSH; else `git` over SSH with the user's own keys. HTTPS is refused.
  case sshOnly = 3
  /// Never the `git` command, and only the vault's key signs in. What it can't do it refuses, saying why.
  case vaultKeyOnly = 4

  /// What an unset level means.
  public static let standard = GitSecurityLevel.inAppFirst

  public var id: Int { rawValue }

  public var title: String {
    switch self {
    case .useGit: "Use git"
    case .inAppFirst: "In-app first"
    case .sshOnly: "SSH only"
    case .vaultKeyOnly: "Vault key only"
    }
  }

  /// Whether raising to this level stops pushes until this device's key is on the server.
  public var needsKeyOnServer: Bool { self >= .sshOnly }

  /// Why a repository on another device can't fetch, pull or push at this level; nil when it can.
  public var otherDeviceRefusal: String? {
    guard self == .vaultKeyOnly else { return nil }
    return "Vault key only is on (Settings ▸ Security). Git on another device signs in with that device’s own keys, "
      + "so fetch, pull and push are off for repositories there."
  }

  /// What to tell the user about a repository on another device at this level, while it keeps working.
  public var otherDeviceWarning: String? {
    guard self == .sshOnly else { return nil }
    return "Git on that device uses its own keys and settings, which it can’t check."
  }
}

extension GitSecurityLevel: Comparable {
  public static func < (lhs: GitSecurityLevel, rhs: GitSecurityLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One value from `git config --list`.
public struct GitSetting: Sendable, Hashable {
  public var key: String
  public var value: String

  public init(key: String, value: String) {
    self.key = key
    self.value = value
  }

  /// What `git config --list -z` printed: `key\nvalue\0`, or `key\0` for a key without a value (true).
  public static func parse(_ text: String) -> [GitSetting] {
    text.split(separator: "\0").map { entry in
      let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      return GitSetting(key: String(parts[0]), value: parts.count > 1 ? String(parts[1]) : "true")
    }
  }
}

/// A network action the app can do itself, on a repository on this device.
public enum GitNetworkAction: Sendable, Hashable {
  case fetch
  case pull
  case push(force: Bool)
  case deleteBranch(name: String, remote: String, expected: String)
}

/// Where a host's SSH address really leads, as the user's `ssh` would read it (`ssh -G`, which connects to nothing).
public struct SSHClientAddress: Sendable, Hashable {
  public var hostname: String
  public var port: Int?
  /// Through a `ProxyCommand` or `ProxyJump`.
  public var isProxied: Bool

  public init(hostname: String, port: Int?, isProxied: Bool) {
    self.hostname = hostname
    self.port = port
    self.isProxied = isProxied
  }
}

/// What one network action works with.
public struct GitNetworkRequest: Sendable {
  public var level: GitSecurityLevel
  /// What git reads here (`git config --list`), nil where there's no git to ask: `.git/config` is all there is.
  public var settings: [GitSetting]?
  /// Whether there's a `git` to fall back to, and to run the local half of a pull or clone.
  public var hasGit: Bool
  public var sshClientAddress: (@Sendable (String) async -> SSHClientAddress?)?
  public var progress: (@Sendable (String) -> Void)?

  public init(
    level: GitSecurityLevel, settings: [GitSetting]? = nil, hasGit: Bool = false,
    sshClientAddress: (@Sendable (String) async -> SSHClientAddress?)? = nil,
    progress: (@Sendable (String) -> Void)? = nil
  ) {
    self.level = level
    self.settings = settings
    self.hasGit = hasGit
    self.sshClientAddress = sshClientAddress
    self.progress = progress
  }
}

/// How a network action the engine was given ended.
public enum GitNetworkOutcome: Sendable, Equatable {
  /// It's all done.
  case done
  /// The network half is done: `git` does the local half (a pull's merge or rebase, a clone's checkout).
  case fetched
  /// The engine can't do this (`reason`), and the level lets `git` try with the user's own credentials. `remotes` or
  /// `url` narrow what git works on; `refusal` is what still has to be said afterwards (remotes the level refused).
  case useGit(reason: String, remotes: [String]? = nil, url: String? = nil, refusal: String? = nil)
}

/// The app's own git on the network: GitEngine, which needs GitKit's models and so can't be called from here.
public protocol GitNetworkEngine: Sendable {
  /// Puts remotes `sshOnly` moved to SSH back where they were, once the level has gone back down.
  func restoreMovedRemotes(in worktree: URL)
  @concurrent func perform(
    _ action: GitNetworkAction, in worktree: URL, request: GitNetworkRequest
  ) async throws -> GitNetworkOutcome
  @concurrent func clone(_ remote: String, to destination: URL, request: GitNetworkRequest) async throws -> GitNetworkOutcome
}

/// What `Repository`'s network actions go through. The app sets it once at launch. Without it (Linux, Windows, other
/// apps using GitKit) they run `git` as `useGit` does.
public enum GitNetwork {
  public struct Configuration: Sendable {
    public var engine: (any GitNetworkEngine)?
    /// Read for every action, so a level changed here or on another device applies from the next one on.
    public var level: @Sendable () async -> GitSecurityLevel
    public var sshClientAddress: (@Sendable (String) async -> SSHClientAddress?)?

    public init(
      engine: (any GitNetworkEngine)?, level: @escaping @Sendable () async -> GitSecurityLevel,
      sshClientAddress: (@Sendable (String) async -> SSHClientAddress?)? = GitNetwork.defaultSSHClientAddress
    ) {
      self.engine = engine
      self.level = level
      self.sshClientAddress = sshClientAddress
    }
  }

  private static let store = OSAllocatedUnfairLock<Configuration?>(initialState: nil)
  /// A configuration for one task and what it starts, for tests running side by side.
  @TaskLocal public static var scoped: Configuration?

  public static func configure(_ configuration: Configuration?) {
    store.withLock { $0 = configuration }
  }

  static var configuration: Configuration? { scoped ?? store.withLock { $0 } }

  static var engine: (any GitNetworkEngine)? { configuration?.engine }

  /// The level network actions follow now.
  public static func level() async -> GitSecurityLevel {
    await configuration?.level() ?? .useGit
  }

  /// `ssh -G` on the Mac; nothing elsewhere.
  public static var defaultSSHClientAddress: (@Sendable (String) async -> SSHClientAddress?)? {
    #if os(macOS)
      { await SSHClientConfig.address(of: $0) }
    #else
      nil
    #endif
  }

  // MARK: The token on other devices

  private static let acceptedKey = "GitTokenAcceptedRemotes"

  /// The user accepted the HTTPS offer for a repository on another device: git there may get the token for `host` from
  /// now on, at levels that don't send it by themselves. Kept per device.
  static func acceptToken(forHost host: String, device: String, path: String) {
    var accepted = UserDefaults.standard.stringArray(forKey: acceptedKey) ?? []
    let entry = acceptedEntry(host: host, device: device, path: path)
    guard !accepted.contains(entry) else { return }
    accepted.append(entry)
    UserDefaults.standard.set(accepted, forKey: acceptedKey)
  }

  static func isTokenAccepted(forHost host: String, device: String, path: String) -> Bool {
    (UserDefaults.standard.stringArray(forKey: acceptedKey) ?? []).contains(acceptedEntry(host: host, device: device, path: path))
  }

  private static func acceptedEntry(host: String, device: String, path: String) -> String {
    [device, path, host.lowercased()].joined(separator: "\n")
  }
}
