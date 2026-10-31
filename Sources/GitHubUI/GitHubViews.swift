import ComponentKit
import Foundation
import GitHubKit
import SwiftUI

/// Another vault account's GitHub sign-in, with Use: the account without one keeps a copy of its own. A row of a
/// `FormCard`.
///
/// ```swift
/// FormCard("Signed in on another account") {
///   ForEach(offers) { offer in GitHubSignInOfferRow(offer: offer) { account.use(offer) } }
/// }
/// ```
public struct GitHubSignInOfferRow: View {
  let offer: GitHubSignInOffer
  let use: () -> Void

  public init(offer: GitHubSignInOffer, use: @escaping () -> Void) {
    self.offer = offer
    self.use = use
  }

  public var body: some View {
    GroupRow {
      HStack(spacing: 10) {
        Avatar(name: offer.credential.login, size: 28)
        VStack(alignment: .leading, spacing: 1) {
          Text("@\(offer.credential.login)").kitFont(.headline)
          Text("Signed in on \(offer.accountName)").kitFont(.caption)
        }
      }
    } trailing: {
      Button("Use", action: use)
        .buttonStyle(.kit)
    }
  }
}

/// An OAuth scope name, as GitHub shows it.
public struct ScopeLabel: View {
  let scope: String

  public init(scope: String) { self.scope = scope }

  public var body: some View {
    Text(scope)
      .kitFont(.monoSmall)
      .foregroundStyle(.kitSecondary)
  }
}

extension URL {
  /// A GitHub avatar's URL asking for the image at twice `size` (`s=`), for Retina screens.
  ///
  /// ```swift
  /// Avatar(name: user.login, url: user.avatarURL?.gitHubAvatar(size: 40), size: 40)
  /// ```
  public func gitHubAvatar(size: CGFloat) -> URL {
    guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
    components.queryItems = (components.queryItems ?? []).filter { $0.name != "s" }
      + [URLQueryItem(name: "s", value: String(Int(size * 2)))]
    return components.url ?? self
  }
}
