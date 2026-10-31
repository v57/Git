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
        GitHubAvatar(url: nil, name: offer.credential.login, size: 28)
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

/// A GitHub avatar, or the initials avatar while it loads or without a network.
public struct GitHubAvatar: View {
  let url: URL?
  let name: String
  let size: CGFloat

  public init(url: URL?, name: String, size: CGFloat) {
    self.url = url
    self.name = name
    self.size = size
  }

  public var body: some View {
    AsyncImage(url: sizedURL) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      Avatar(name: name, size: size)
    }
    .frame(width: size, height: size)
    .clipShape(.circle)
  }

  /// Asks for the image at twice the point size (`s=`), for Retina screens.
  private var sizedURL: URL? {
    guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url
    }
    components.queryItems = (components.queryItems ?? []).filter { $0.name != "s" }
      + [URLQueryItem(name: "s", value: String(Int(size * 2)))]
    return components.url ?? url
  }
}
