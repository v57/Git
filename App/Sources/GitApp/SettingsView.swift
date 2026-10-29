import ComponentKit
import GitHubKit
import GitKit
import GitUI
import SwiftUI
import VaultKit
import VaultUI

enum SettingsKeys {
  static let gitPath = "GitExecutablePath"
  /// The Settings window's pane, and the Accounts pane's id (a window's account picker opens it).
  static let pane = "SettingsPane"
  static let accountsPane = "Accounts"
}

struct SettingsView: View {
  @AppStorage(SettingsKeys.pane) private var pane = "General"

  var body: some View {
    KitSettings(selection: $pane) {
      SettingsPane("General", systemImage: "gearshape") { GeneralSettingsView() }
      SettingsPane("GitHub", systemImage: "cloud", hue: .indigo) { AccountGitHubSettings() }
      SettingsPane(SettingsKeys.accountsPane, systemImage: "person.2", hue: .indigo, section: "v57") {
        VaultAccountsSettings()
      }
    }
    .frame(width: 680, height: 460)
  }
}

private struct GeneralSettingsView: View {
  @AppStorage(SettingsKeys.gitPath) private var gitPath = ""
  @State private var resolved: String?
  @State private var version: String?

  var body: some View {
    FormCard(
      "Git",
      footer: "Leave empty to use Homebrew git, then /usr/bin/git (which needs the Command Line Tools). "
        + "Pushing uses your SSH agent, Keychain and git credential helpers, or your GitHub "
        + "account for github.com while you're signed in."
    ) {
      FormRow(
        "git executable", help: "Automatic when empty", systemImage: "terminal", hue: .gray,
        field: TextField("Automatic", text: $gitPath))
      if let resolved {
        FormRow("Using", help: [resolved, version].compactMap { $0 }.joined(separator: " · "), systemImage: "checkmark", hue: .green)
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
