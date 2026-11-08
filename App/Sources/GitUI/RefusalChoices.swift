import ComponentKit
import GitKit
import SwiftUI
import VaultKit

/// What the app offers when the security level refused a fetch, pull or push because a remote stayed on HTTPS: its move
/// to SSH didn't work. Both apps show the refusal with these choices instead of only OK.
public enum RefusalChoices {
  /// The refusal, then what each choice does.
  public static func message(_ refusal: GitNetworkRefusal) -> String {
    var lines = [refusal.message]
    if offersAddKey(refusal) {
      lines.append(String(localized: "GitHub doesn’t know this device’s key yet. Add Key on GitHub copies it and opens GitHub’s page for it, then try again: the remote moves to SSH."))
    }
    if refusal.offersHTTPS {
      lines.append(String(localized: "Use HTTPS This Time signs in with your GitHub account for this action only. The remote stays on HTTPS, and the next action asks again."))
    }
    return lines.joined(separator: "\n\n")
  }

  /// Whether adding this device's key on GitHub would let the move work.
  public static func offersAddKey(_ refusal: GitNetworkRefusal) -> Bool {
    refusal.keyRefused && refusal.httpsHosts.contains { $0.lowercased() == "github.com" } && deviceKey != nil
  }

  /// The notice's buttons: Add Key on GitHub, and Use HTTPS This Time (the default) with `retry`.
  @MainActor public static func buttons(
    _ refusal: GitNetworkRefusal, retry: (@MainActor @Sendable () async -> Void)?, openURL: OpenURLAction
  ) -> [KitConfirmationButton] {
    var buttons: [KitConfirmationButton] = []
    if offersAddKey(refusal), let key = deviceKey, let url = URL(string: "https://github.com/settings/ssh/new") {
      buttons.append(
        KitConfirmationButton("Add Key on GitHub", isDefault: retry == nil) {
          KitPasteboard.copy(key.publicKey)
          openURL(url)
        })
    }
    if let retry {
      buttons.append(KitConfirmationButton("Use HTTPS This Time", isDefault: true) { Task { await retry() } })
    }
    return buttons
  }

  @MainActor private static var deviceKey: VaultDeviceKey? {
    let vault = Vault.shared
    return vault.deviceKeys.first { $0.id == vault.deviceID }
  }
}
