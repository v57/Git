import ComponentKit
import GitHubKit
import GitKit
import SwiftUI

/// Publishes a repository that has no remote: creates it on GitHub (private or public, for the
/// user or one of their organizations), adds it as `origin` and pushes the current branch.
struct PublishRepositorySheet: View {
  let session: RepositorySession
  @Environment(GitHubAccount.self) private var account
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var description = ""
  /// The organization that will own it, or `nil` for the signed-in user.
  @State private var organization: String?
  @State private var isPrivate = true
  @State private var creating: Task<Void, Never>?
  @State private var error: String?
  @State private var signInRequest: GitHubSignInRequest?

  init(session: RepositorySession) {
    self.session = session
    _name = State(initialValue: NewRepository.normalizedName(session.repository.name))
  }

  private var owner: String { organization ?? account.user?.login ?? "" }
  private var repositoryName: String { NewRepository.normalizedName(name) }
  private var branch: String { session.status?.branch ?? "the current branch" }

  /// A private repository needs the `repo` scope; `public_repo` can only create public ones.
  private var needsPrivateAccess: Bool {
    isPrivate && account.permissions.repositories != .all
  }

  private var canPublish: Bool {
    account.isSignedIn && !repositoryName.isEmpty && creating == nil && !needsPrivateAccess
      && session.status?.branch != nil && session.headCommit != nil
  }

  var body: some View {
    KitSheet(
      title: "Publish to GitHub", meta: "Creates github.com/\(owner)/\(repositoryName) and pushes \(branch) to it as origin.",
      systemImage: "icloud.and.arrow.up", status: creating == nil ? .idle : .working, width: 480
    ) {
      if account.isSignedIn {
        FormCard(footer: footerText) {
          FormRow("Owner", systemImage: "person", hue: .indigo) {
            Picker("Owner", selection: $organization) {
              Text(account.user?.login ?? "").tag(String?.none)
              ForEach(account.organizations) { organization in
                Text(organization.login).tag(Optional(organization.login))
              }
            }
            .labelsHidden()
            .fixedSize()
          }
          if !account.permissions.organizations {
            GrantHint(text: "Only organizations where your membership is public are listed.") {
              grant(.organizations)
            }
          }
          FormRow("Name", systemImage: "character.cursor.ibeam", field: TextField("Name", text: $name))
          FormRow(
            "Description", help: "Optional", systemImage: "text.alignleft",
            field: TextField("Description", text: $description))
          FormRow("Visibility", help: visibilityText, systemImage: isPrivate ? "lock" : "globe", hue: .teal) {
            KitSegmented(selection: $isPrivate, options: [("Private", true), ("Public", false)])
          }
          if needsPrivateAccess {
            GrantHint(text: "Git can only create public repositories with your current permissions.") {
              grant(.privateRepositories)
            }
          }
        }
        .disabled(creating != nil)
      } else {
        FormCard {
          FormRow("Sign in to GitHub", help: "To create a repository for this one.", systemImage: "person.crop.circle") {
            Button("Sign In…") { signInRequest = GitHubSignInRequest(permissions: .recommended) }.buttonStyle(.kit)
          }
        }
      }
      if let error {
        Banner("Couldn’t publish", message: error, systemImage: "exclamationmark.triangle", hue: .red)
      }
    } footer: {
      if creating != nil {
        SheetStatus("Creating \(owner)/\(repositoryName)…", systemImage: "icloud.and.arrow.up", status: .working)
      }
      Spacer(minLength: 0)
      Button("Cancel") {
        creating?.cancel()
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      Button("Publish", action: publish)
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(!canPublish)
    }
    .animation(.kit, value: account.isSignedIn)
    .animation(.kit, value: needsPrivateAccess)
    .sheet(item: $signInRequest) { GitHubSignInSheet(permissions: $0.permissions) }
    // Picks up organizations joined since sign-in.
    .task(id: account.isSignedIn) { await account.refresh() }
    .onAppear {
      if account.permissions.repositories == .publicOnly { isPrivate = false }
    }
  }

  private func grant(_ permission: GitHubPermission) {
    signInRequest = GitHubSignInRequest(permissions: account.permissions.union(permission.permissions))
  }

  /// What else publishing does, under the form.
  private var footerText: String? {
    var lines: [String] = []
    if account.isSignedIn && account.permissions.repositories != .all {
      lines.append("Pushing uses your own git credentials, since Git’s access is limited to public repositories.")
    }
    if session.headCommit == nil { lines.append("Commit something first: there is nothing to push yet.") }
    return lines.isEmpty ? nil : lines.joined(separator: " ")
  }

  private var visibilityText: String {
    switch (isPrivate, organization) {
    case (true, nil): "Only you and people you invite can see it."
    case (true, let organization?): "Only members of \(organization) with access can see it."
    case (false, _): "Anyone on the internet can see it. You choose who can commit."
    }
  }

  private func publish() {
    guard canPublish, let api = account.api else { return }
    let repository = NewRepository(
      name: repositoryName,
      description: description.trimmingCharacters(in: .whitespacesAndNewlines),
      isPrivate: isPrivate, organization: organization)
    let session = session
    error = nil
    creating = Task {
      defer { creating = nil }
      do {
        let created = try await api.createRepository(repository)
        dismiss()
        // Pushing shows in the toolbar; a failure shows in the window's alert, and the remote
        // stays so Push retries it.
        Task { await session.publish(to: created.cloneURL.absoluteString) }
      } catch {
        guard !Task.isCancelled else { return }
        if case GitHubError.unauthorized = error { account.signOut() }
        self.error = error.localizedDescription
      }
    }
  }
}

/// A missing permission's explanation with Grant…, under the control that needs it.
private struct GrantHint: View {
  let text: String
  let grant: () -> Void

  var body: some View {
    FormRow("Needs a permission", help: text, systemImage: "key", hue: .orange) {
      Button("Grant…", action: grant).buttonStyle(.kit)
    }
  }
}
