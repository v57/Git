import Foundation
import GitKit
import VaultKit
import VaultUI

/// Whether git outside the app (Terminal, scripts, agents) commits as the user too: the user's choice, asked once
/// per Mac at the first commit where git's own settings name nobody, and only for the Personal account. On yes, the
/// Personal profile goes into `~/.gitconfig` (`Repository.setGlobalIdentity`); Settings ▸ General does it later.
@MainActor
enum TerminalIdentity {
  static let option = VaultProfileOption(
    title: "Use in Terminal too", help: "Writes them to ~/.gitconfig, so git in Terminal and your agents commit as you.",
    systemImage: "terminal", accept: "Use in Terminal", decline: "Only in Git")

  private static let askedKey = "TerminalIdentityAsked"

  /// Whether a commit in `account` with `configured` settings should offer it.
  static func shouldOffer(account: VaultAccount, configured: Repository.IdentityConfiguration) -> Bool {
    account.isPersonal && !configured.any && !UserDefaults.standard.bool(forKey: askedKey)
  }

  /// Records the user's answer; on yes, writes `profile` to the global git config. A failed write asks again later.
  static func answered(_ use: Bool, profile: VaultProfile) async {
    if use {
      do { try await Repository.setGlobalIdentity(name: profile.name, email: profile.email) } catch { return }
    }
    UserDefaults.standard.set(true, forKey: askedKey)
  }
}
