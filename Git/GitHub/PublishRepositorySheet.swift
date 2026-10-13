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
    VStack(alignment: .leading, spacing: 0) {
      Form {
        if account.isSignedIn {
          Section {
            Picker("Owner", selection: $organization) {
              Text(account.user?.login ?? "").tag(String?.none)
              ForEach(account.organizations) { organization in
                Text(organization.login).tag(Optional(organization.login))
              }
            }
            if !account.permissions.organizations {
              GrantHint(text: "Only organizations where your membership is public are listed.") {
                grant(.organizations)
              }
            }
            TextField("Name", text: $name)
            TextField("Description", text: $description, prompt: Text("Optional"))
            Picker("Visibility", selection: $isPrivate) {
              Text("Private").tag(true)
              Text("Public").tag(false)
            }
            .pickerStyle(.segmented)
            if needsPrivateAccess {
              GrantHint(text: "Git can only create public repositories with your current permissions.") {
                grant(.privateRepositories)
              }
            }
          } header: {
            Text("Publish to GitHub")
          } footer: {
            footer
          }
        } else {
          Section("Publish to GitHub") {
            HStack {
              Text("Sign in to GitHub to create a repository for this one.")
                .foregroundStyle(.secondary)
              Spacer()
              Button("Sign In…") { signInRequest = GitHubSignInRequest(permissions: .recommended) }
            }
          }
        }
        if let error {
          Text(error)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
      .formStyle(.grouped)
      .disabled(creating != nil)
      HStack {
        if creating != nil {
          ProgressView().controlSize(.small)
          Text("Creating \(owner)/\(repositoryName)…")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel") {
          creating?.cancel()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button("Publish", action: publish)
          .keyboardShortcut(.defaultAction)
          .disabled(!canPublish)
      }
      .padding([.horizontal, .bottom], 20)
    }
    .frame(width: 480)
    .animation(.app, value: account.isSignedIn)
    .animation(.app, value: needsPrivateAccess)
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

  private var footer: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(visibilityText)
      Text("Creates github.com/\(owner)/\(repositoryName) and pushes \(branch) to it as origin.")
      if account.isSignedIn && account.permissions.repositories != .all {
        Text("Pushing uses your own git credentials, since Git’s access is limited to public repositories.")
      }
      if session.headCommit == nil {
        Text("Commit something first: there is nothing to push yet.")
          .foregroundStyle(.orange)
      }
    }
    .foregroundStyle(.secondary)
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
    HStack {
      Text(text)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      Spacer()
      Button("Grant…", action: grant)
        .controlSize(.small)
    }
  }
}
