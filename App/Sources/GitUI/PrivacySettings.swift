import ComponentKit
import GitKit
import GitRemote
import SwiftUI
import VaultKit
import VaultUI

/// Settings ▸ Privacy: what reaches the network on its own, each off until the user turns it on (`features`, then
/// auto-fetch), the switch for iCloud, which starts on, and what Git sends. Every row of the list comes from `Ideas/Security/network-git.md`: change them together.
public struct PrivacySettingsPane<Features: View>: View {
  @ViewBuilder var features: Features

  public init(@ViewBuilder features: () -> Features) { self.features = features() }

  public var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      features
      AutoFetchCard()
      VaultICloudCard()
      KitPrivacyParties("Git", footer: "Links you click open in your browser, which talks to those sites itself.") {
        KitPrivacyParty(
          "Your Git servers", systemImage: "server.rack", hue: .blue,
          when: "When you clone, fetch, pull or push, and when auto-fetch runs if it’s on.",
          why: "The servers your remotes name, such as GitHub, GitLab or your own. Each sees your IP address and how "
            + "you sign in, and receives what you push.")
        KitPrivacyParty(
          "GitHub", systemImage: "cloud", hue: .indigo,
          when: "When you sign in, open Settings ▸ GitHub or publish a repository.",
          why: "It needs your sign-in to do that. Git reads your name, picture and organizations, and creates the "
            + "repository you asked for.")
        #if !os(iOS)
          KitPrivacyParty(
            "GitHub, for updates", systemImage: "arrow.down.circle", hue: .indigo,
            when: "When you choose Check for Updates, or once a day if that’s on above.",
            why: "Git’s releases are there. It sees your IP address, and downloads only start when you say so.")
        #endif
        #if os(macOS) || os(iOS)
          KitPrivacyParty(
            "Apple", systemImage: "icloud", hue: .gray,
            when: "All the time, while iCloud is on for this device and on above.",
            why: "It keeps your repository list, groups, security level and each repository’s last status (its branch "
              + "and the names of changed files) in your private iCloud, encrypted on this device first.")
        #endif
        KitPrivacyParty(
          "Your other devices", systemImage: "laptopcomputer", hue: .teal,
          when: "When you open a repository on one, or Git reopens it at launch, and when you act on one.",
          why: "Git connects straight to that device over SSH and runs git there. Its git then talks to its servers "
            + "with its own keys.")
        #if !os(iOS)
          KitPrivacyParty(
            "Whatever your git setup names", systemImage: "terminal", hue: .gray,
            when: "At Use git, and where the app hands an action to git.",
            why: "git talks to what your remotes, submodules, LFS and config name, with your own keys and helpers.")
        #endif
      }
    }
  }
}

extension PrivacySettingsPane where Features == EmptyView {
  public init() { features = EmptyView() }
}

/// Auto-fetch's switch, and when on, when and how often. On this device only.
private struct AutoFetchCard: View {
  @State private var auto = AutoFetch.shared

  var body: some View {
    @Bindable var auto = auto
    FormCard("Auto-fetch", footer: footer) {
      FormRow(
        "Fetch automatically", help: auto.isOn ? "On this device" : "Off: Git only fetches when you ask",
        systemImage: "arrow.clockwise", hue: .blue
      ) {
        Toggle("Fetch automatically", isOn: $auto.isOn.animation(.kit))
          .toggleStyle(.kitSwitch)
          .kitLabelsHidden()
      }
      if auto.isOn {
        FormRow("When", systemImage: "clock", hue: .blue) {
          KitPicker(
            selection: $auto.schedule.moment,
            segments: [
              KitSegment("At Startup", value: .startup), KitSegment("When Selected", value: .selection),
              KitSegment("Both", value: .both),
            ])
        }
        FormRow("Each repository, at most", systemImage: "calendar", hue: .blue) {
          KitPicker(
            selection: $auto.schedule.interval,
            segments: [
              KitSegment("Once an Hour", value: .hour), KitSegment("Once a Day", value: .day),
              KitSegment("Once a Week", value: .week),
            ])
        }
      }
    }
  }

  private var footer: String? {
    guard auto.isOn else { return nil }
    let moment =
      switch auto.schedule.moment {
      case .startup: "Fetches the repositories on this device when Git starts."
      case .selection: "Fetches a repository when you select it."
      case .both: "Fetches the repositories on this device when Git starts, and any repository when you select it."
      }
    return moment + " " + levelNote + " A failed fetch stays quiet."
  }

  /// What the Security level means for a fetch nobody just asked for.
  private var levelNote: String {
    #if os(macOS)
      switch GitSecurity.level {
      case .useGit: "At Use git it runs git with your own setup, so a key that needs a passphrase or Touch ID may ask."
      case .inAppFirst: "It follows In-app first, as your own fetches do."
      case .sshOnly: "At SSH only, repositories with HTTPS remotes wait until you next fetch, pull or push yourself."
      case .vaultKeyOnly:
        "At Vault key only, repositories with HTTPS remotes wait for you, and those on your other devices are left out."
      }
    #else
      switch GitSecurity.level {
      case .useGit, .inAppFirst: "It follows your Security level, as your own fetches do."
      case .sshOnly: "At SSH only, repositories with HTTPS remotes wait until you next fetch, pull or push yourself."
      case .vaultKeyOnly:
        "At Vault key only, repositories with HTTPS remotes wait for you, and those on your other devices are left out."
      }
    #endif
  }
}
