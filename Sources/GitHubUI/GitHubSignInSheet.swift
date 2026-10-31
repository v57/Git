import ComponentKit
import Foundation
import GitHubKit
import SwiftUI

/// Signing in to GitHub, or changing what the app may do: choose permissions, enter the code on github.com, then see
/// what GitHub granted. The account stays as it was until the new token arrives, so cancelling a change of
/// permissions keeps the old ones. Present it with `.kitSheet`; it closes itself.
///
/// ```swift
/// .kitSheet(item: $request) { request in
///   GitHubSignInSheet(
///     account: account, appName: "Git", permissions: request.permissions,
///     offers: { account.signInOffers }, use: { account.use($0) }
///   ) { BranchGlyph() }
/// }
/// GitHubSignInSheet(
///   account: account, appName: "Markdown",
///   permissions: GitHubPermissions(repositories: .all, organizations: false, workflows: false), choices: [],
///   systemImage: "doc.text")
/// ```
public struct GitHubSignInSheet<Glyph: View>: View {
  let account: GitHubAccount
  let appName: String
  let choices: [GitHubPermission]
  let offers: () -> [GitHubSignInOffer]
  let use: (GitHubSignInOffer) -> Void
  let glyph: Glyph
  @Environment(\.kitDismiss) private var dismiss
  @Environment(\.kitIdiom) private var idiom
  @State private var requested: GitHubPermissions
  /// Whether Continue was pressed; before that the sheet shows the chooser.
  @State private var started = false
  /// What another account's sign-in that was used instead has (`GitHubSignInOffer`).
  @State private var used: GitHubPermissions?

  /// - Parameters:
  ///   - account: the sign-in to start or change.
  ///   - appName: the app, as the sheet's text names it ("Choose what Git can do with your account").
  ///   - permissions: what the chooser starts with.
  ///   - choices: the permissions the chooser has a switch for, under the repositories' choice.
  ///   - offers: other vault accounts' sign-ins, read when the chooser appears; one the user picks goes to `use`,
  ///     which signs `account` in with it.
  ///   - glyph: the app's glyph on its accent tile, opposite GitHub's.
  public init(
    account: GitHubAccount, appName: String, permissions: GitHubPermissions,
    choices: [GitHubPermission] = [.organizations, .workflows], offers: @escaping () -> [GitHubSignInOffer] = { [] },
    use: @escaping (GitHubSignInOffer) -> Void = { _ in }, @ViewBuilder glyph: () -> Glyph
  ) {
    self.account = account
    self.appName = appName
    self.choices = choices
    self.offers = offers
    self.use = use
    self.glyph = glyph()
    _requested = State(initialValue: permissions)
  }

  private enum Step: Hashable {
    case choose, waiting, done, failed
  }

  private var step: Step {
    if used != nil { return .done }
    guard started else { return .choose }
    switch account.signInStep {
    case nil: return .choose
    case .requestingCode, .waiting: return .waiting
    case .succeeded: return .done
    case .failed: return .failed
    }
  }

  private var phase: GitHubConnectionPhase {
    switch step {
    case .choose: .idle
    case .waiting: .waiting
    case .done: .connected
    case .failed: .failed
    }
  }

  public var body: some View {
    VStack(spacing: 0) {
      GitHubConnectionView(phase: phase) { glyph }
        .padding(.top, 26)
        .padding(.bottom, 14)
      ZStack {
        switch step {
        case .choose:
          ChooseStep(
            appName: appName, choices: choices, requested: $requested, offers: offers, start: start, use: useOffer,
            cancel: close)
        case .waiting: WaitingStep(appName: appName, cancel: close)
        case .done: DoneStep(appName: appName, requested: used ?? requested, finish: close)
        case .failed: FailedStep(retry: start, cancel: close)
        }
      }
      .id(step)
      .transition(.page)
      .padding([.horizontal, .bottom], idiom == .phone ? 20 : 28)
    }
    // A phone's sheet is as wide as the screen.
    .frame(width: idiom == .phone ? nil : 540)
    .environment(account)
    .animation(.kit, value: step)
    .onDisappear {
      if step == .waiting { account.cancelSignIn() } else { account.endSignIn() }
    }
  }

  private func start() {
    started = true
    account.signInInBrowser(requesting: requested)
  }

  private func useOffer(_ offer: GitHubSignInOffer) {
    use(offer)
    if account.isSignedIn { used = offer.credential.permissions }
  }

  private func close() {
    if step == .waiting { account.cancelSignIn() } else { account.endSignIn() }
    dismiss()
  }
}

extension GitHubSignInSheet where Glyph == Image {
  /// The sheet with an SF Symbol on the app's tile.
  public init(
    account: GitHubAccount, appName: String, permissions: GitHubPermissions,
    choices: [GitHubPermission] = [.organizations, .workflows], offers: @escaping () -> [GitHubSignInOffer] = { [] },
    use: @escaping (GitHubSignInOffer) -> Void = { _ in }, systemImage: String
  ) {
    self.init(
      account: account, appName: appName, permissions: permissions, choices: choices, offers: offers, use: use
    ) { Image(systemName: systemImage) }
  }
}

// MARK: - Choose

private struct ChooseStep: View {
  @Environment(GitHubAccount.self) private var account
  @Environment(\.kitIdiom) private var idiom
  let appName: String
  let choices: [GitHubPermission]
  @Binding var requested: GitHubPermissions
  let offers: () -> [GitHubSignInOffer]
  let start: () -> Void
  let use: (GitHubSignInOffer) -> Void
  let cancel: () -> Void
  /// Other vault accounts' sign-ins, while this one has none.
  @State private var shownOffers: [GitHubSignInOffer] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      StepTitle(
        account.isSignedIn ? "Change GitHub permissions" : "Sign in to GitHub",
        "Choose what \(appName) can do with your account. GitHub lists the same permissions before you approve.")

      if !shownOffers.isEmpty {
        FormCard("Signed in on another account") {
          ForEach(shownOffers) { offer in
            GitHubSignInOfferRow(offer: offer) { use(offer) }
          }
        }
        SectionTitle("Or sign in to GitHub with these permissions:")
      }

      VStack(alignment: .leading, spacing: 8) {
        SectionTitle("Repositories")
        // Side by side, or one above the other on a phone.
        (idiom == .phone ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: KitMetrics.gutter))) {
          RepositoryOption(
            title: "Public and private", scope: "repo",
            detail: "Read and write every repository you can access.",
            isSelected: requested.repositories == .all
          ) { requested.repositories = .all }
          RepositoryOption(
            title: "Public only", scope: "public_repo",
            detail: "Read and write public repositories only.",
            isSelected: requested.repositories == .publicOnly
          ) { requested.repositories = .publicOnly }
        }
        .fixedSize(horizontal: false, vertical: idiom == .phone)
      }

      if !choices.isEmpty {
        FormCard {
          ForEach(choices) { permission in
            FormRow(permission.title, help: permission.detail, systemImage: permission.systemImage, hue: permission.hue) {
              Toggle(permission.title, isOn: $requested.binding(for: permission).animation(.kit))
                .toggleStyle(.kitSwitch)
                .kitLabelsHidden()
            }
          }
        }
      }

      // The buttons go under the scopes on a phone.
      (idiom == .phone
        ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 12)) : AnyLayout(HStackLayout(spacing: 8)))
      {
        (Text("Requests ") + Text(requested.scopes.joined(separator: " · ")).font(KitFont.monoSmall.font))
          .kitFont(.caption)
          .contentTransition(.interpolate)
          .animation(.kit, value: requested)
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 8) {
          Button("Cancel", action: cancel)
            .buttonStyle(.kit)
            .keyboardShortcut(.cancelAction)
          Button(action: start) {
            Label("Continue on GitHub", systemImage: "arrow.up.right")
              .labelStyle(.kitTrailingIcon)
          }
          .buttonStyle(.kitPrimary)
          .keyboardShortcut(.defaultAction)
        }
      }
      .padding(.top, 2)
    }
    .onAppear { shownOffers = offers() }
  }
}

extension Binding where Value == GitHubPermissions {
  /// Whether `permission` is asked for: organizations or workflows on their own, private repositories as the
  /// repositories' choice.
  fileprivate func binding(for permission: GitHubPermission) -> Binding<Bool> {
    switch permission {
    case .organizations: self.organizations
    case .workflows: self.workflows
    case .privateRepositories:
      Binding<Bool>(
        get: { wrappedValue.repositories == .all },
        set: { wrappedValue.repositories = $0 ? .all : .publicOnly })
    }
  }
}

/// One of the two repository choices: a card with a radio mark that takes the accent ring when selected.
private struct RepositoryOption: View {
  let title: String
  let scope: String
  let detail: String
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    ChoiceCard(isOn: .init(get: { isSelected }, set: { if $0 { select() } })) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(title).kitFont(.headline)
          ScopeLabel(scope: scope)
        }
        Text(detail)
          .kitFont(.caption)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }
}

// MARK: - Waiting

private struct WaitingStep: View {
  @Environment(GitHubAccount.self) private var account
  let appName: String
  let cancel: () -> Void

  private var code: DeviceCode? {
    if case .waiting(let code) = account.signInStep { return code }
    return nil
  }

  var body: some View {
    VStack(spacing: 16) {
      StepTitle(
        "Enter this code on GitHub",
        "It’s copied, and github.com/login/device is open in your browser.")

      ZStack {
        if let code {
          let groups = code.userCode.split(separator: "-").map(String.init)
          KitSafetyCode(groups: groups, columns: groups.count)
            .fixedSize()
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else {
          LiveIcon(systemImage: "ellipsis", hue: .gray, status: .working, size: 18)
        }
      }
      .frame(minHeight: 44)
      .animation(.kit, value: code)

      HStack(spacing: 8) {
        KitCopyButton("Copy Code", value: code?.userCode ?? "", copiedWhen: code?.userCode)
          .buttonStyle(.kit)
        Button {
          if let code { account.openVerificationPage(code) }
        } label: {
          Label("Open GitHub Again", systemImage: "arrow.up.right")
            .labelStyle(.kitTrailingIcon)
        }
        .buttonStyle(.kit)
      }
      .disabled(code == nil)

      HStack(spacing: 8) {
        LiveIcon(systemImage: "ellipsis", hue: .gray, status: .working, size: 18)
        Text("Waiting for you to approve \(appName) on GitHub…")
        Spacer()
        if let code {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(code.expiresAt.timeIntervalSince(context.date)))
            Text("Expires in \(left / 60):\(String(format: "%02d", left % 60))")
              .kitFont(.caption)
              .monospacedDigit()
              .contentTransition(.numericText(countsDown: true))
              .animation(.kit, value: left)
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(.kitFillSoft, in: .rect(cornerRadius: KitMetrics.radiusLarge, style: .continuous))

      HStack {
        Spacer()
        Button("Cancel", action: cancel)
          .buttonStyle(.kit)
          .keyboardShortcut(.cancelAction)
      }
    }
  }
}

// MARK: - Done

private struct DoneStep: View {
  @Environment(GitHubAccount.self) private var account
  let appName: String
  let requested: GitHubPermissions
  let finish: () -> Void
  @State private var shown = false

  private var chips: [String] {
    let granted = account.permissions
    var chips = [granted.repositories == .all ? "Public and private repositories" : "Public repositories"]
    if granted.organizations { chips.append(GitHubPermission.organizations.title) }
    if granted.workflows { chips.append(GitHubPermission.workflows.title) }
    return chips
  }

  /// What was asked for but not granted.
  private var missing: [String] {
    GitHubPermission.allCases
      .filter { $0.isGranted(in: requested) && !$0.isGranted(in: account.permissions) }
      .map(\.title)
  }

  var body: some View {
    VStack(spacing: 14) {
      StepTitle("Connected as \(account.user?.login ?? "GitHub")", "\(appName) can now do this with your account:")
      KitFlowLayout(spacing: 6, alignment: .center) {
        ForEach(Array(chips.enumerated()), id: \.element) { index, chip in
          Chip(chip, systemImage: "checkmark", hue: .green)
            .scaleEffect(shown ? 1 : 0.9)
            .offset(y: shown ? 0 : 6)
            .opacity(shown ? 1 : 0)
            .animation(.spring(response: 0.35, dampingFraction: 0.65).delay(0.65 + Double(index) * 0.09), value: shown)
        }
      }
      if !missing.isEmpty {
        Banner(
          "GitHub granted less than \(appName) asked for",
          message: "Not granted: \(missing.formatted()). \(appName) asks again when something needs it.",
          systemImage: "exclamationmark.triangle", hue: .orange)
          .opacity(shown ? 1 : 0)
          .animation(.kit.delay(0.9), value: shown)
      }
      HStack {
        Spacer()
        Button("Done", action: finish)
          .buttonStyle(.kitPrimary)
          .keyboardShortcut(.defaultAction)
      }
    }
    .onAppear { shown = true }
  }
}

// MARK: - Failed

private struct FailedStep: View {
  @Environment(GitHubAccount.self) private var account
  let retry: () -> Void
  let cancel: () -> Void

  private var error: GitHubError? {
    if case .failed(let error) = account.signInStep { return error }
    return nil
  }

  private var title: String {
    switch error {
    case .signInDeclined: "Sign-in was declined"
    case .codeExpired: "The code expired"
    default: "Couldn’t sign in"
    }
  }

  var body: some View {
    VStack(spacing: 14) {
      StepTitle(title, error?.localizedDescription ?? "")
      HStack(spacing: 8) {
        Spacer()
        Button("Cancel", action: cancel)
          .buttonStyle(.kit)
          .keyboardShortcut(.cancelAction)
        Button("Try Again", action: retry)
          .buttonStyle(.kitPrimary)
          .keyboardShortcut(.defaultAction)
      }
    }
  }
}

// MARK: - Pieces

/// A step's title and what to do, centred under the tiles.
private struct StepTitle: View {
  let title: String
  let message: String

  init(_ title: String, _ message: String) {
    self.title = title
    self.message = message
  }

  var body: some View {
    VStack(spacing: 4) {
      Text(title).kitFont(.title2)
      Text(message)
        .kitFont(.body)
        .foregroundStyle(.kitSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
  }
}

/// A heading over a group, lined up with `FormCard`'s title.
private struct SectionTitle: View {
  let title: String

  init(_ title: String) { self.title = title }

  var body: some View {
    Text(title)
      .kitFont(.headline)
      .padding(.horizontal, 12)
      .accessibilityAddTraits(.isHeader)
  }
}
