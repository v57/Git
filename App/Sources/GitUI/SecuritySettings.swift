import ComponentKit
import GitKit
import GitRemote
import SwiftUI

/// Settings ▸ Security: what protects the user's work, how strict network actions are, what that means next to other
/// Git clients, and this device's key.
public struct SecuritySettingsPane: View {
  public init() {}

  public var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SecurityProtectionCard()
      SecuritySettingsCard()
      SecurityComparisonCard()
      DeviceSSHKeyCard()
    }
  }
}

/// The level as this device applies it: iPhone and iPad have no git, so Use git means the same as In-app first there.
private var appliedLevel: GitSecurityLevel {
  #if os(macOS)
    GitSecurity.level
  #else
    max(GitSecurity.level, .inAppFirst)
  #endif
}

/// What keeps the user's work safe, in plain words, at the level they picked.
private struct SecurityProtectionCard: View {
  var body: some View {
    let level = appliedLevel
    FormCard("What protects your work") {
      FormRow("This device’s key", help: key(level), systemImage: "key", hue: .green)
      FormRow("Your GitHub sign-in", help: signIn(level), systemImage: "person.badge.key", hue: .indigo)
      FormRow("The servers you connect to", help: servers(level), systemImage: "checkmark.shield", hue: .teal)
      FormRow("Your repositories", help: repositories, systemImage: "folder", hue: .blue)
      FormRow(
        "What syncs",
        help: "Your repository list, groups, this level and each repository’s last status (its branch and the names "
          + "of changed files) go through iCloud, encrypted on this device first. Your code and commits don’t.",
        systemImage: "icloud", hue: .gray)
    }
  }

  private func key(_ level: GitSecurityLevel) -> String {
    let made =
      "Made inside this device’s Secure Enclave, a chip nothing can copy it out of, not even this app. It signs while "
      + "the device is unlocked, without asking for Face ID or Touch ID."
    return level == .useGit ? made + " At Use git, servers don’t see it: git signs in with your own keys." : made
  }

  private func signIn(_ level: GitSecurityLevel) -> String {
    let kept = "Kept in the keychain the v57 apps share, and in iCloud Keychain."
    return level == .useGit
      ? kept + " At Use git, git gets it while it runs, and so can anything git runs."
      : kept + " It’s used only inside the app, over HTTPS: git and anything git runs never get it, except git on "
        + "another device once you accept switching a repository there to HTTPS."
  }

  private func servers(_ level: GitSecurityLevel) -> String {
    switch level {
    case .useGit: "Your own ssh setup checks them."
    case .vaultKeyOnly: "A server’s key is remembered the first time, and a changed key is refused."
    default:
      #if os(macOS)
        "In the app, a server’s key is remembered the first time and a changed key is refused. Where git takes over, "
          + "your own ssh setup checks it."
      #else
        "A server’s key is remembered the first time, and a changed key is refused."
      #endif
    }
  }

  private var repositories: String {
    #if os(macOS)
      "They stay in their folders, as git keeps them. Git doesn’t encrypt them: FileVault, in System Settings, does."
    #else
      "They stay in this app’s folder, which the Files app shows. Git doesn’t add encryption of its own."
    #endif
  }
}

/// Settings' security level: how far network actions may go on all the user's devices. Changing it talks to no server:
/// the first action that needs the key finds out whether the server has it.
public struct SecuritySettingsCard: View {
  @State private var raisingTo: GitSecurityLevel?

  public init() {}

  /// The levels that do something here: iPhone and iPad have no git to use.
  private var levels: [GitSecurityLevel] {
    #if os(macOS)
      GitSecurityLevel.allCases
    #else
      GitSecurityLevel.allCases.filter { $0 != .useGit }
    #endif
  }

  public var body: some View {
    let level = appliedLevel
    FormCard("Security level", footer: footer(level)) {
      FormRow("Minimum level", systemImage: "lock.shield", hue: .green) {
        KitPicker(
          selection: Binding(get: { level }, set: { change(to: $0, from: level) }),
          segments: levels.map { KitSegment($0.title, value: $0) })
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
      case .useGit, .inAppFirst: "Repositories here sign in with this device’s key or your GitHub token. All your devices share this level."
      case .sshOnly: "HTTPS remotes move to SSH when you next use them, and sign in with this device’s key. All your devices share this level."
      case .vaultKeyOnly:
        "Only this device’s key signs in: HTTPS is refused. Fetch, pull and push are off for repositories on your other devices. All your devices share this level."
      }
    #endif
  }
}

/// What this level means next to other Git clients. Every sentence about another app comes from its own documentation:
/// sources and dates in `Ideas/Security/network-git.md`. Check them again before changing this.
private struct SecurityComparisonCard: View {
  var body: some View {
    let level = appliedLevel
    #if os(macOS)
      KitSecurityComparison(
        "Git",
        footer: "Any program you run can read a key file, and only a passphrase keeps what’s in it safe. "
          + "From each app’s documentation, November 2026."
      ) {
        KitComparisonRow(
          "Your SSH key", systemImage: "key", here: key(level),
          others: [
            ("Tower", "A private key file you point it to, or your SSH agent."),
            ("GitKraken", "A key pair it generates or you browse to, or your SSH agent."),
          ])
        KitComparisonRow(
          "Your password or token", systemImage: "person.badge.key", hue: .indigo, here: token(level),
          others: [
            ("GitHub Desktop", "A short-lived token in the system keychain."),
            ("Tower", "A password in the Keychain, which it hands to git through an Askpass program."),
          ])
        KitComparisonRow(
          "Your git setup", systemImage: "terminal", hue: .gray, here: setup(level),
          others: [
            ("Tower", "Reaches remotes with git commands, where git’s own setup applies."),
            ("GitKraken", "Runs hooks such as pre-push."),
          ])
      }
    #else
      KitSecurityComparison("Git", footer: "From Working Copy’s manual, November 2026.") {
        KitComparisonRow(
          "Your SSH key", systemImage: "key",
          here: "Always this device’s key, made in its Secure Enclave. It signs without asking for Face ID or Touch ID.",
          others: [
            ("Working Copy", "Keys it generates or you import, which can also be kept in the Secure Enclave, behind Face ID or Touch ID.")
          ])
      }
    #endif
  }

  #if os(macOS)
    private func key(_ level: GitSecurityLevel) -> String {
      switch level {
      case .useGit: "Your own keys and ssh setup, as in the apps below."
      case .vaultKeyOnly: "Only this device’s key, in its Secure Enclave, which nothing can copy. Key files aren’t used."
      default: "This device’s key, in its Secure Enclave, which nothing can copy. Your own keys only where git takes over."
      }
    }

    private func token(_ level: GitSecurityLevel) -> String {
      level == .useGit
        ? "A long-lived GitHub token, in git’s environment while it runs."
        : "A long-lived GitHub token, used only inside the app. git on this Mac never gets it."
    }

    private func setup(_ level: GitSecurityLevel) -> String {
      switch level {
      case .useGit: "git runs with all of it, and hooks can read your token."
      case .vaultKeyOnly: "Left out of network actions: pre-push hooks don’t run and ~/.ssh/config isn’t read."
      default: "A repository with a pre-push hook or LFS goes to git, without your token."
      }
    }
  #endif
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
