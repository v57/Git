import ComponentKit
import GitHubKit
import SwiftUI

/// Settings › GitHub: Connect GitHub while signed out; the account, Change Permissions… and the
/// granted permissions (each missing one with Grant…) while signed in.
public struct GitHubSettingsView: View {
  @Environment(GitHubAccount.self) private var account
  @State private var request: GitHubSignInRequest?
  /// Other vault accounts' sign-ins, while this one has none.
  @State private var offers: [GitHubSignInOffer] = []

  public init() {}

  public var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      ZStack {
        if account.isSignedIn {
          signedIn.transition(.page)
        } else {
          signedOut.transition(.page)
        }
      }
      .animation(.kit, value: account.isSignedIn)
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .kitSheet(item: $request) { GitHubSignInSheet(permissions: $0.permissions) }
    .task(id: account.isSignedIn) { offers = account.signInOffers }
  }

  private var signedOut: some View {
    VStack(spacing: 14) {
      GitHubConnectionView(phase: .idle, tileSize: 52)
      Text("Connect GitHub")
        .font(.system(size: 17, weight: .semibold))
        .padding(.top, 4)
      Text("Create repositories and push to GitHub with an account that stays inside Git. Other apps can’t read its token.")
        .foregroundStyle(.kitSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 400)
        .fixedSize(horizontal: false, vertical: true)
      if let notice = account.notice {
        Text(notice)
          .foregroundStyle(Hue.red.text)
          .multilineTextAlignment(.center)
      }
      Button("Sign In…") { request = GitHubSignInRequest(permissions: .recommended) }
        .buttonStyle(.kitPrimary)
        .padding(.top, 4)
      if !offers.isEmpty {
        VStack(spacing: 0) {
          ForEach(offers) { offer in
            if offer.id != offers.first?.id { Divider().padding(.horizontal, 12) }
            GitHubSignInOfferRow(offer: offer) { account.use(offer) }
          }
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
        .frame(maxWidth: 400)
        .padding(.top, 10)
      }
    }
    .padding(.horizontal, 32)
    .padding(.top, 34)
    .padding(.bottom, 30)
    .frame(maxWidth: .infinity)
    .settingsCard()
  }

  private var signedIn: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        GitHubAvatar(url: account.user?.avatarURL, name: account.user?.login ?? "", size: 40)
        VStack(alignment: .leading, spacing: 1) {
          Text(account.user?.name ?? account.user?.login ?? "")
            .fontWeight(.semibold)
          if let login = account.user?.login, let url = URL(string: "https://github.com/\(login)") {
            Link("github.com/\(login)", destination: url)
              .font(.system(size: 12))
          }
        }
        Spacer()
        Button("Change Permissions…") { request = GitHubSignInRequest(permissions: account.permissions) }
          .buttonStyle(.kit)
        Button("Sign Out") { account.signOut() }
          .buttonStyle(.kit)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .settingsCard()

      VStack(alignment: .leading, spacing: 6) {
        Text("Permissions")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.kitSecondary)
          .padding(.horizontal, 4)
        VStack(spacing: 0) {
          ForEach(GitHubPermission.allCases) { permission in
            if permission != .privateRepositories { Divider().padding(.leading, 16) }
            PermissionRow(permission: permission, isGranted: permission.isGranted(in: account.permissions)) {
              request = GitHubSignInRequest(permissions: account.permissions.union(permission.permissions))
            }
          }
        }
        .settingsCard()
        Text("While you’re signed in with access to private repositories, Git uses this account for github.com over HTTPS instead of your credential helpers. Revoke it any time on [GitHub › Settings › Applications](https://github.com/settings/applications).")
          .font(.system(size: 12))
          .foregroundStyle(.kitSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
          .padding(.top, 4)
      }
    }
    .task { await account.refresh() }
  }
}

private struct PermissionRow: View {
  let permission: GitHubPermission
  let isGranted: Bool
  let grant: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(permission.title).fontWeight(.medium)
          ScopeLabel(scope: permission.scope)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.kitFillSoft, in: .rect(cornerRadius: KitMetrics.radiusXS))
        }
        Text(permission.detail)
          .font(.system(size: 12))
          .foregroundStyle(.kitSecondary)
      }
      Spacer()
      ZStack {
        if isGranted {
          Chip("Granted", systemImage: "checkmark", hue: .green)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else {
          Button("Grant…", action: grant)
            .buttonStyle(.kit)
            .transition(.opacity)
        }
      }
      .animation(.spring(response: 0.35, dampingFraction: 0.65), value: isGranted)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .frame(minHeight: 52)
  }
}

extension View {
  /// A white rounded card on the Settings background.
  fileprivate func settingsCard() -> some View {
    kitSurface(.card)
  }
}

/// A GitHub avatar, or the initials avatar while it loads or without a network.
struct GitHubAvatar: View {
  let url: URL?
  let name: String
  let size: CGFloat

  var body: some View {
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
