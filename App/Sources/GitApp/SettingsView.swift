import ComponentKit
import GitHubKit
import GitKit
import GitRemote
import GitUI
import SwiftUI
import UpdateKit
import VaultKit
import VaultUI

enum SettingsKeys {
  static let gitPath = "GitExecutablePath"
  /// The Settings window's pane, and the Accounts pane's id (a window's account picker opens it).
  static let pane = "SettingsPane"
  static let accountsPane = "Accounts"
}

struct SettingsView: View {
  let updater: AppUpdater
  @KitStorage(SettingsKeys.pane) private var pane = "General"

  var body: some View {
    KitSettings(selection: $pane, window: .hiddenTitleBar) {
      SettingsPane("General", systemImage: "gearshape") { GeneralSettingsView() }
      SettingsPane("GitHub", systemImage: "cloud", hue: .indigo) { AccountGitHubSettings() }
      #if os(macOS)
        SettingsPane("Security", systemImage: "lock.shield", hue: .green) { SecuritySettingsPane() }
      #endif
      SettingsPane("Privacy", systemImage: "hand.raised", hue: .blue) {
        PrivacySettingsPane { UpdateCheckCard(updater: updater) }
      }
      SettingsPane("Accounts", systemImage: "person.2", hue: .indigo, section: "v57", id: SettingsKeys.accountsPane) {
        VaultAccountsSettings()
      }
      // Your devices, and Git on iPhone and iPad runs this Mac's git over SSH: which can sign in, and the other keys.
      SettingsPane("Remote", systemImage: "network", hue: .teal, section: "v57") { VaultRemoteSettings() }
    } footer: {
      DeviceKeyCopyButton()
    }
    .frame(width: 680, height: 460)
  }
}

private struct GeneralSettingsView: View {
  @KitStorage(SettingsKeys.gitPath) private var gitPath = ""
  @State private var resolved: String?
  @State private var version: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      gitCard
      TerminalIdentityCard()
    }
  }

  private var gitCard: some View {
    FormCard(
      "Git",
      footer: """
        Leave empty to use Homebrew git, then /usr/bin/git (which needs the Command Line Tools). \
        Settings ▸ Security decides what network actions use.
        """
    ) {
      FormRow(
        "git executable", help: "Automatic when empty", systemImage: "terminal", hue: .gray,
        field: TextField("Automatic", text: $gitPath))
      if let resolved {
        FormRow(
          "Using", help: "\([resolved, version].compactMap { $0 }.joined(separator: " · "))", systemImage: "checkmark",
          hue: .green)
      } else {
        FormRow("Using", systemImage: "xmark", error: "git not found")
      }
    }
    .task(id: gitPath) {
      GitExecutable.customPath = gitPath
      resolved = GitExecutable.current?.path
      version = await GitExecutable.version()
    }
  }
}

/// Who git outside the app commits as (`~/.gitconfig`), and a button to make it the Personal account's name and email
/// (`TerminalIdentity`).
private struct TerminalIdentityCard: View {
  @State private var vaults = Vaults.shared
  @State private var global = GitGlobalIdentity.read()
  @State private var failure: String?

  var body: some View {
    let profile = vaults.profile(for: .personal)
    let current = [global.name, global.email.map { "<\($0)>" }].compactMap { $0 }.joined(separator: " ")
    FormCard(
      "Terminal",
      footer: "Git in Terminal, scripts and agents read ~/.gitconfig. The app commits with your name either way."
    ) {
      FormRow(
        "Commits as", help: current.isEmpty ? "Nobody yet: git there can't commit" : "\(current)",
        systemImage: "terminal", hue: .gray, error: failure.map { "\($0)" }
      ) {
        if profile.isComplete, global.name != profile.name || global.email != profile.email {
          Button("Use \(profile.name)") { Task { await use(profile) } }
        }
      }
    }
  }

  private func use(_ profile: VaultProfile) async {
    do {
      try await Repository.setGlobalIdentity(name: profile.name, email: profile.email)
      failure = nil
    } catch {
      failure = error.localizedDescription
    }
    global = GitGlobalIdentity.read()
  }
}

/// Settings › GitHub for one vault account: the frontmost window's, or the one picked at the top (shown while
/// there are accounts beside Personal). Each account signs in on its own (`GitHubAccount.forAccount`).
private struct AccountGitHubSettings: View {
  @State private var vaults = Vaults.shared
  @State private var frontmost = FrontmostAccount.shared
  /// The account picked here; nil follows the frontmost window.
  @State private var picked: String?

  private var accountID: String {
    // A deleted account falls back to Personal.
    vaults.account(id: picked ?? frontmost.id)?.id ?? VaultAccount.personal.id
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if !vaults.accounts.isEmpty {
        KitAccountPicker(
          accounts: vaults.allAccounts.map(\.kitAccount),
          selection: Binding(get: { accountID }, set: { picked = $0 }), style: .compact)
      }
      GitHubSettingsView()
        .environment(GitHubAccount.forAccount(accountID))
        .id(accountID)
    }
    .onChange(of: frontmost.id) { picked = nil }
  }
}
