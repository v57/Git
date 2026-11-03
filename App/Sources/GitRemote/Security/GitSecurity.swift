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
      Vault.shared.personalVault.gitSettings?.securityLevel.flatMap(GitSecurityLevel.init(rawValue:)) ?? .standard
    }
    set {
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
    /// `GIT_DEBUG_SECURITY_LEVEL`: a level to start with (1 to 4). `GIT_DEBUG_WRITE_PUBLIC_KEY`: a file for this device's
    /// public key line, published in the vault as Settings shows it, for a test server's `authorized_keys`. For trying
    /// the levels in an `--in-memory` run, on repositories that stay out of the user's vault.
    private static func applyDebugEnvironment() {
      let environment = ProcessInfo.processInfo.environment
      if let level = environment["GIT_DEBUG_SECURITY_LEVEL"].flatMap(Int.init).flatMap(GitSecurityLevel.init(rawValue:)) {
        self.level = level
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
