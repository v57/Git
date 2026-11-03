import ComponentKit
import GitKit
import GitRemote
import SwiftUI

/// Settings' security level: how far network actions may go on all the user's devices. Changing it talks to no server:
/// the first action that needs the key finds out whether the server has it.
public struct SecuritySettingsCard: View {
  @State private var raisingTo: GitSecurityLevel?

  public init() {}

  public var body: some View {
    let level = GitSecurity.level
    FormCard("Security", footer: footer(level)) {
      FormRow("Minimum level", systemImage: "lock.shield", hue: .green) {
        KitPicker(
          selection: Binding(get: { level }, set: { change(to: $0, from: level) }),
          segments: GitSecurityLevel.allCases.map { KitSegment($0.title, value: $0) })
      }
    }
    .kitConfirmation(
      "Turn on \(raisingTo?.title ?? "")?",
      isPresented: Binding(get: { raisingTo != nil }, set: { if !$0 { raisingTo = nil } }),
      message: "Fetching and pushing over SSH stop working until this device’s key below is on each server. "
        + "Add it first if it isn’t there yet.",
      systemImage: "lock.shield", confirm: "Turn On", role: nil
    ) {
      if let raisingTo { GitSecurity.level = raisingTo }
    }
  }

  private func change(to new: GitSecurityLevel, from old: GitSecurityLevel) {
    if new > old, new.needsKeyOnServer {
      raisingTo = new
    } else {
      GitSecurity.level = new
    }
  }

  private func footer(_ level: GitSecurityLevel) -> String {
    #if os(macOS)
      switch level {
      case .useGit:
        "Network actions run git with your own setup, plus your GitHub token in its environment, where anything git runs can read it."
      case .inAppFirst:
        "Network actions run in the app with this device’s key or your GitHub token. If that can’t work they run git with your own keys and helpers, never the token."
      case .sshOnly:
        "Network actions run in the app, and HTTPS remotes move to SSH when you next use them. If that can’t work they run git over SSH with your own keys. HTTPS is refused."
      case .vaultKeyOnly:
        "Network actions never run git and only this device’s key signs in. Off here: pre-push hooks, ~/.ssh/config, submodules, LFS and folder remotes. What it can’t do, it refuses and says why."
      }
    #else
      switch level {
      case .useGit, .inAppFirst: "Repositories here sign in with this device’s key or your GitHub token."
      case .sshOnly: "HTTPS remotes move to SSH when you next use them, and sign in with this device’s key."
      case .vaultKeyOnly:
        "Only this device’s key signs in: HTTPS is refused. Fetch, pull and push are off for repositories on your other devices."
      }
    #endif
  }
}

/// Above a repository on another device: what the level means for it, as git there uses that device's own keys.
public struct OtherDeviceSecurityBanner: View {
  public init() {}

  public var body: some View {
    let level = GitSecurity.level
    if level.otherDeviceRefusal != nil {
      Banner(
        "Fetch, pull and push are off here", message: "Vault key only is on, and git on that device signs in with its own keys.",
        systemImage: "lock.shield", hue: .orange)
    } else if let warning = level.otherDeviceWarning {
      Banner("SSH only isn’t enforced here", message: warning, systemImage: "exclamationmark.shield", hue: .orange)
    }
  }
}
