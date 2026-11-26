import ComponentKit
import GitHubKit
import GitRemote
import SwiftUI

extension GitHubAccount {
  /// GitHub in the sidebar's activity card, only when it needs the user: a sign-in that failed, or an account GitHub
  /// signed out on its own (a revoked or expired token). `signIn` opens where the user signs in.
  public func attentionLine(signIn: @escaping @MainActor () -> Void) -> SidebarActivity? {
    if case .failed(let error)? = signInStep {
      return SidebarActivity(
        id: "github", String(localized: "GitHub sign-in failed"), detail: error.errorDescription,
        systemImage: "person.crop.circle.badge.exclamationmark", hue: .red, status: .failed, action: signIn)
    }
    if !isSignedIn, let notice {
      return SidebarActivity(
        id: "github", String(localized: "Signed out of GitHub"), detail: notice,
        systemImage: "person.crop.circle.badge.exclamationmark", hue: .orange, action: signIn)
    }
    return nil
  }
}

extension RemoteAction {
  /// A sidebar status line's title while it runs: "Fetching atlas", "Fetching 3 repositories".
  public func running(_ names: [String]) -> String {
    if names.count == 1 {
      switch self {
      case .fetch: return String(localized: "Fetching \(names[0])")
      case .pull: return String(localized: "Pulling \(names[0])")
      case .push: return String(localized: "Pushing \(names[0])")
      }
    }
    switch self {
    case .fetch: return String(localized: "Fetching \(names.count) repositories")
    case .pull: return String(localized: "Pulling \(names.count) repositories")
    case .push: return String(localized: "Pushing \(names.count) repositories")
    }
  }

  /// The line's title after it failed.
  public var failed: String {
    switch self {
    case .fetch: String(localized: "Fetch failed")
    case .pull: String(localized: "Pull failed")
    case .push: String(localized: "Push failed")
    }
  }
}
