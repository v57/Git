import ComponentKit
import GitHubKit
import SwiftUI

/// Signing in to GitHub, or changing what Git may do: choose permissions, enter the code on
/// github.com, then see what GitHub granted. The account stays as it was until the new token
/// arrives, so cancelling a change of permissions keeps the old ones.
struct GitHubSignInSheet: View {
  @Environment(GitHubAccount.self) private var account
  @Environment(\.kitDismiss) private var dismiss
  @State private var requested: GitHubPermissions
  /// Whether Continue was pressed; before that the sheet shows the chooser.
  @State private var started = false

  init(permissions: GitHubPermissions) {
    _requested = State(initialValue: permissions)
  }

  private enum Step: Hashable {
    case choose, waiting, done, failed
  }

  private var step: Step {
    guard started else { return .choose }
    switch account.signInStep {
    case nil: return .choose
    case .requestingCode, .waiting: return .waiting
    case .succeeded: return .done
    case .failed: return .failed
    }
  }

  private var phase: GitHubConnectionView.Phase {
    switch step {
    case .choose: .idle
    case .waiting: .waiting
    case .done: .connected
    case .failed: .failed
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      GitHubConnectionView(phase: phase)
        .padding(.top, 26)
        .padding(.bottom, 14)
      ZStack {
        switch step {
        case .choose: ChooseStep(requested: $requested, start: start, cancel: close)
        case .waiting: WaitingStep(cancel: close)
        case .done: DoneStep(requested: requested, finish: close)
        case .failed: FailedStep(retry: start, cancel: close)
        }
      }
      .id(step)
      .transition(.page)
      .padding([.horizontal, .bottom], 28)
    }
    .frame(width: 540)
    .animation(.kit, value: step)
    .onDisappear {
      if step == .waiting { account.cancelSignIn() } else { account.endSignIn() }
    }
  }

  private func start() {
    started = true
    account.signInInBrowser(requesting: requested)
  }

  private func close() {
    if step == .waiting { account.cancelSignIn() } else { account.endSignIn() }
    dismiss()
  }
}

// MARK: - Choose

private struct ChooseStep: View {
  @Environment(GitHubAccount.self) private var account
  @Binding var requested: GitHubPermissions
  let start: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      StepTitle(
        account.isSignedIn ? "Change GitHub permissions" : "Sign in to GitHub",
        "Choose what Git can do with your account. GitHub lists the same permissions before you approve.")

      VStack(alignment: .leading, spacing: 6) {
        Text("Repositories")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.kitSecondary)
          .padding(.horizontal, 2)
        HStack(spacing: 8) {
          RepositoryOption(
            title: "Public and private", scope: "repo",
            detail: "Read and write every repository you can access.",
            isSelected: requested.repositories == .all
          ) { requested.repositories = .all }
          RepositoryOption(
            title: "Public only", scope: "public_repo",
            detail: "Pushing keeps using your own git credentials.",
            isSelected: requested.repositories == .publicOnly
          ) { requested.repositories = .publicOnly }
        }
      }

      VStack(spacing: 0) {
        PermissionToggle(permission: .organizations, isOn: $requested.organizations)
        Divider().padding(.horizontal, 12)
        PermissionToggle(permission: .workflows, isOn: $requested.workflows)
      }
      .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))

      HStack(spacing: 8) {
        (Text("Requests ") + Text(requested.scopes.joined(separator: " · ")).font(.system(size: 11).monospaced()))
          .font(.system(size: 11))
          .foregroundStyle(.kitSecondary)
          .contentTransition(.interpolate)
          .animation(.kit, value: requested)
        Spacer()
        Button("Cancel", action: cancel)
          .buttonStyle(.kit)
          .keyboardShortcut(.cancelAction)
        Button(action: start) {
          Label("Continue on GitHub", systemImage: "arrow.up.right")
            .labelStyle(TrailingIconLabelStyle())
        }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
      }
      .padding(.top, 2)
    }
  }
}

/// One of the two repository choices: a card with a radio mark that takes the accent ring when
/// selected.
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

private struct PermissionToggle: View {
  let permission: GitHubPermission
  @Binding var isOn: Bool

  var body: some View {
    Toggle(isOn: $isOn.animation(.kit)) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(permission.title).fontWeight(.semibold)
          ScopeLabel(scope: permission.scope)
        }
        Text(permission.detail)
          .font(.system(size: 12))
          .foregroundStyle(.kitSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .toggleStyle(.kitSwitch)
    .padding(.horizontal, 12)
    .padding(.vertical, 11)
  }
}

// MARK: - Waiting

private struct WaitingStep: View {
  @Environment(GitHubAccount.self) private var account
  let cancel: () -> Void
  /// Shown while the code was just copied, by the sheet or the Copy button.
  @State private var copiedAt: Date? = .now

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
          DeviceCodeView(code: code.userCode)
        } else {
          LiveIcon(systemImage: "ellipsis", hue: .gray, status: .working, size: 18)
        }
      }
      .frame(height: 62)

      HStack(spacing: 8) {
        Button {
          guard let code else { return }
          account.copy(code)
          copiedAt = .now
        } label: {
          CopyLabel(copiedAt: copiedAt)
        }
        .buttonStyle(.kit)
        Button {
          if let code { account.openVerificationPage(code) }
        } label: {
          Label("Open GitHub Again", systemImage: "arrow.up.right")
            .labelStyle(TrailingIconLabelStyle())
        }
        .buttonStyle(.kit)
      }
      .disabled(code == nil)

      HStack(spacing: 8) {
        LiveIcon(systemImage: "ellipsis", hue: .gray, status: .working, size: 18)
        Text("Waiting for you to approve Git on GitHub…")
        Spacer()
        if let code {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(code.expiresAt.timeIntervalSince(context.date)))
            Text("Expires in \(left / 60):\(String(format: "%02d", left % 60))")
              .font(.system(size: 12).monospacedDigit())
              .foregroundStyle(.kitSecondary)
              .contentTransition(.numericText(countsDown: true))
              .animation(.kit, value: left)
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10, style: .continuous))

      HStack {
        Spacer()
        Button("Cancel", action: cancel)
          .buttonStyle(.kit)
          .keyboardShortcut(.cancelAction)
      }
    }
  }
}

/// "Copy Code", or a tick and "Copied" for 1.8 seconds after copying.
private struct CopyLabel: View {
  let copiedAt: Date?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.3)) { context in
      let copied = copiedAt.map { context.date.timeIntervalSince($0) < 1.8 } ?? false
      HStack(spacing: 6) {
        if copied {
          Image(systemName: "checkmark")
            .fontWeight(.bold)
            .transition(.scale(scale: 0.3).combined(with: .opacity))
        }
        Text(copied ? "Copied" : "Copy Code")
          .contentTransition(.interpolate)
      }
      .foregroundStyle(copied ? Color.green : Color.primary)
      .animation(.spring(response: 0.3, dampingFraction: 0.6), value: copied)
    }
  }
}

/// The code in tiles that pop in one after another.
private struct DeviceCodeView: View {
  let code: String
  @State private var shown = false

  var body: some View {
    HStack(spacing: 6) {
      ForEach(Array(code.enumerated()), id: \.offset) { index, character in
        Group {
          if character == "-" {
            Text("–").foregroundStyle(.kitTertiary).frame(width: 14)
          } else {
            Text(String(character))
              .frame(width: 40, height: 54)
              .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 9, style: .continuous))
              .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.separator))
          }
        }
        .font(.system(size: 26, weight: .semibold, design: .monospaced))
        .scaleEffect(shown ? 1 : 0.8)
        .offset(y: shown ? 0 : 10)
        .opacity(shown ? 1 : 0)
        .animation(.spring(response: 0.42, dampingFraction: 0.62).delay(0.12 + Double(index) * 0.055), value: shown)
      }
    }
    .textSelection(.enabled)
    .onAppear { shown = true }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Code \(code)")
  }
}

// MARK: - Done

private struct DoneStep: View {
  @Environment(GitHubAccount.self) private var account
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
      StepTitle("Connected as \(account.user?.login ?? "GitHub")", "Git can now do this with your account:")
      FlowLayout(spacing: 6) {
        ForEach(Array(chips.enumerated()), id: \.element) { index, chip in
          Label(chip, systemImage: "checkmark")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.green)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.green.opacity(0.12), in: .capsule)
            .scaleEffect(shown ? 1 : 0.9)
            .offset(y: shown ? 0 : 6)
            .opacity(shown ? 1 : 0)
            .animation(.spring(response: 0.35, dampingFraction: 0.65).delay(0.65 + Double(index) * 0.09), value: shown)
        }
      }
      if !missing.isEmpty {
        Label {
          Text("GitHub granted less than Git asked for: **\(missing.formatted())**. Git asks again when something needs it.")
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
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

private struct StepTitle: View {
  let title: String
  let message: String

  init(_ title: String, _ message: String) {
    self.title = title
    self.message = message
  }

  var body: some View {
    VStack(spacing: 4) {
      Text(title).font(.system(size: 17, weight: .semibold))
      Text(message)
        .foregroundStyle(.kitSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
  }
}

/// An OAuth scope name, as GitHub shows it.
struct ScopeLabel: View {
  let scope: String

  var body: some View {
    Text(scope)
      .font(.system(size: 11).monospaced())
      .foregroundStyle(.kitSecondary)
  }
}

/// A label with its icon after the title, for buttons that open the browser.
struct TrailingIconLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.title
      configuration.icon.imageScale(.small).fontWeight(.semibold)
    }
  }
}

/// Lays children out in rows, wrapping and centering each row.
private struct FlowLayout: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in rows(width: bounds.width, subviews: subviews) {
      var x = bounds.midX - row.width / 2
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private func rows(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
    var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      if let last = rows.last, last.width + spacing + size.width <= width {
        rows[rows.count - 1].indices.append(index)
        rows[rows.count - 1].width += spacing + size.width
        rows[rows.count - 1].height = max(last.height, size.height)
      } else {
        rows.append(([index], size.width, size.height))
      }
    }
    return rows
  }
}
