import Foundation
import GitKit
import VaultKit

#if canImport(GitEngine)
  import GitEngine
#endif

/// The user's `GitSecurityLevel`: Settings ▸ Security, kept in Personal's vault so all their devices follow it. A vault
/// that hasn't got one means `GitSecurityLevel.standard`.
public enum GitSecurity {
  public static var level: GitSecurityLevel {
    get {
      #if DEBUG
        if let debugLevel { return debugLevel }
      #endif
      return Vault.shared.personalVault.gitSettings?.securityLevel.flatMap(GitSecurityLevel.init(rawValue:)) ?? .standard
    }
    set {
      #if DEBUG
        debugLevel = nil
      #endif
      Vault.shared.personalVault.save(VaultGitSettings(securityLevel: newValue.rawValue))
    }
  }

  /// Why `repository` can't reach its remotes at this level; nil when it can. Only a repository on another device can
  /// be off altogether.
  public static func refusal(for repository: Repository) -> String? {
    repository.isRemote ? level.otherDeviceRefusal : nil
  }

  /// Makes network actions follow the level, with GitEngine in the app and this device's key for SSH. Platforms without
  /// GitEngine stay as they were: `git` with the app's token.
  public static func install() {
    #if canImport(GitEngine)
      GitNetwork.configure(
        GitNetwork.Configuration(engine: GitEngineNetwork(), level: { await MainActor.run { level } }))
      DeviceKeySSH.install()
    #endif
    #if DEBUG
      applyDebugEnvironment()
    #endif
  }

  #if DEBUG
    /// `GIT_DEBUG_SECURITY_LEVEL`'s level, until one is picked in Settings. It stays out of the vault, which syncs.
    private static var debugLevel: GitSecurityLevel?

    /// `GIT_DEBUG_SECURITY_LEVEL`: a level to start with (1 to 4). `GIT_DEBUG_WRITE_PUBLIC_KEY`: a file for this device's
    /// public key line, published in the vault as Settings shows it, for a test server's `authorized_keys`. For trying
    /// the levels in an `--in-memory` run, on repositories that stay out of the user's vault. `GIT_DEBUG_CREDENTIAL`:
    /// `host:username:password`, a made-up sign-in for that host, to see where a token goes.
    private static func applyDebugEnvironment() {
      let environment = ProcessInfo.processInfo.environment
      debugLevel = environment["GIT_DEBUG_SECURITY_LEVEL"].flatMap(Int.init).flatMap(GitSecurityLevel.init(rawValue:))
      if let parts = environment["GIT_DEBUG_CREDENTIAL"]?.split(separator: ":", maxSplits: 2), parts.count == 3 {
        let credential = GitCredential(username: String(parts[1]), password: String(parts[2]))
        GitCredentials.set(credential, for: String(parts[0]))
        GitCredentials.set(credential, for: String(parts[0]), account: VaultAccount.personal.id)
      }
      if let path = environment["GIT_DEBUG_WRITE_PUBLIC_KEY"] {
        let vault = Vault.shared
        vault.perform { try $0.publishDeviceKey() }
        let line = vault.deviceKeys.first { $0.id == vault.deviceID }?.publicKey ?? ""
        try? Data((line + "\n").utf8).write(to: URL(fileURLWithPath: path))
      }
    }
  #endif
}
