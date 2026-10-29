import GitHubKit
import GitUI
import SwiftUI
import VaultKit
import VaultUI

/// A main window: one vault account (Personal, or one the user works for), kept with the window, and its own
/// repository list on that account's vault (`RepositoryLibrary`). The sidebar's picker switches it; a window
/// switched to another account starts over with that account's list.
struct GitWindow: View {
  @SceneStorage("vault.account") private var accountID = VaultAccount.personal.id
  @Environment(\.openSettings) private var openSettings
  @Environment(\.openWindow) private var openWindow

  /// The account a window that Open in New Window opened starts on, taken by the first window that appears.
  private static var pendingAccount: String?

  var body: some View {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--in-memory") {
        // Scripted runs and screenshots: a vault of their own, without the picker, so the user's accounts stay out.
        AccountWindow(vault: .shared)
      } else {
        scope
      }
    #else
      scope
    #endif
  }

  private var scope: some View {
    VaultAccountScope(
      selection: $accountID,
      manage: { [openSettings] in
        UserDefaults.standard.set(SettingsKeys.accountsPane, forKey: SettingsKeys.pane)
        openSettings()
      },
      openInNewWindow: { [openWindow] id in
        Self.pendingAccount = id
        openWindow(id: MainWindow.id)
      }
    ) { vault in
      AccountWindow(vault: vault)
    }
    .onAppear {
      guard let id = Self.pendingAccount else { return }
      Self.pendingAccount = nil
      accountID = id
    }
  }
}

/// The window's content on one account, with that account's GitHub sign-in.
private struct AccountWindow: View {
  @State private var library: RepositoryLibrary
  @State private var github: GitHubAccount
  @Environment(\.appearsActive) private var appearsActive

  init(vault: Vault) {
    _library = State(initialValue: RepositoryLibrary(vault: vault))
    // Restored before the library runs git, so its pushes have the account's token.
    _github = State(initialValue: GitHubAccount.forAccount(vault.accountID))
  }

  var body: some View {
    ContentView()
      .environment(library)
      .environment(github)
      .focusedSceneValue(\.repositoryLibrary, library)
      .onChange(of: appearsActive, initial: true) { _, active in
        if active { FrontmostAccount.shared.id = library.vault.accountID }
      }
  }
}

/// The account of the main window that was frontmost last, whose GitHub sign-in Settings shows.
@MainActor @Observable final class FrontmostAccount {
  static let shared = FrontmostAccount()
  var id = VaultAccount.personal.id
}
