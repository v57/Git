import ComponentKit
import GitEngine
import GitHubKit
import GitKit
import GitRemote
import GitUI
import SwiftUI
import VaultKit
import VaultUI

/// Clone: an HTTPS or SSH URL (or `owner/repo` for GitHub) into a folder of its name on this device, with git's progress
/// while it fetches.
struct CloneSheet: View {
  let opened: (LocalRepository) -> Void
  @State private var remote = ""
  @State private var progress: String?
  @State private var error: String?
  @State private var task: Task<Void, Never>?
  @Environment(\.kitDismiss) private var dismiss
  @Environment(GitHubAccount.self) private var account

  private var url: String? { LocalRepositories.remoteURL(remote) }

  var body: some View {
    KitSheet(title: "Clone Repository", meta: "To this device", systemImage: "square.and.arrow.down", hue: .blue) {
      FormCard(
        footer: account.isSignedIn
          ? "Private GitHub repositories clone with your GitHub sign-in. An SSH address signs in with this device’s key."
          : "Public repositories clone as they are. Sign in to GitHub in Settings for private ones, or use an SSH address, which signs in with this device’s key."
      ) {
        FormRow(
          "URL", help: url.map { LocalRepositories.name(ofRemote: $0) }, systemImage: "link", hue: .blue,
          field: TextField("https://github.com/owner/repo", text: $remote)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .submitLabel(.go)
            .onSubmit(clone))
      }
    } footer: {
      if let error {
        SheetStatus(error, systemImage: "exclamationmark.triangle", hue: .red)
      } else if let progress {
        SheetStatus(progress, systemImage: "arrow.down.circle", hue: .blue)
      }
      Button("Cancel") {
        task?.cancel()
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      Button("Clone", action: clone)
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(url == nil || task != nil)
    }
  }

  private func clone() {
    guard let url, task == nil else { return }
    error = nil
    progress = "Connecting…"
    task = Task {
      do {
        let repository = try await LocalRepositories.shared.clone(url) { line in
          Task { @MainActor in progress = line }
        }
        dismiss()
        opened(repository)
      } catch is CancellationError {
      } catch {
        self.error = RepositoryModel.describe(error)
        progress = nil
      }
      task = nil
    }
  }
}

/// New Repository: an empty one on `main` on this device.
struct NewRepositorySheet: View {
  let opened: (LocalRepository) -> Void
  @State private var name = ""
  @State private var error: String?
  @Environment(\.kitDismiss) private var dismiss

  var body: some View {
    KitSheet(title: "New Repository", meta: "On this device", systemImage: "plus.square", hue: .green) {
      FormCard(footer: "An empty repository on main, in the Files app under Git.") {
        FormRow(
          "Name", systemImage: "folder", hue: .green,
          field: TextField("Repository", text: $name).autocorrectionDisabled().onSubmit(create))
      }
    } footer: {
      if let error { SheetStatus(error, systemImage: "exclamationmark.triangle", hue: .red) }
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Create", action: create)
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
    }
  }

  private func create() {
    do {
      let repository = try LocalRepositories.shared.create(named: name)
      dismiss()
      opened(repository)
    } catch {
      self.error = RepositoryModel.describe(error)
    }
  }
}

/// Open on a Mac: a folder on one of the vault's SSH hosts (a Hub device or any host saved in the Vault app), kept in
/// this app's list. Git checks it's a repository when it opens.
struct AddRemoteSheet: View {
  let added: (SavedRemote) -> Void
  @State private var hosts = RemoteRepositories.hosts()
  @State private var hostID: String?
  @State private var path = "~/Developer/"
  @State private var showsHosts = false
  @Environment(\.kitDismiss) private var dismiss

  private var host: VaultHost? { hosts.first { $0.id == hostID } }

  var body: some View {
    KitSheet(title: "Open on a Mac", meta: "Git runs there over SSH", systemImage: "desktopcomputer", hue: .blue) {
      if hosts.isEmpty {
        Text("Add your Mac in the Vault app first: as an SSH host, or through your Hub.")
          .kitFont(.body)
          .foregroundStyle(.kitSecondary)
          .padding(.horizontal, 4)
      } else {
        FormCard(footer: "The repository’s folder there. ~ is your home folder on that machine.") {
          FormRow("Device", systemImage: "desktopcomputer", hue: .blue) {
            Button {
              showsHosts = true
            } label: {
              Label(host?.displayName ?? "Choose…", systemImage: host?.isViaHub == true ? "point.3.connected.trianglepath.dotted" : "network")
            }
            .buttonStyle(.kit)
            .kitMenu(isPresented: $showsHosts) {
              ForEach(hosts, id: \.id) { host in
                KitMenuOptions(
                  selection: $hostID,
                  segments: [KitSegment(host.displayName, value: Optional(host.id), systemImage: "desktopcomputer")])
                  .kitMenuDetail(host.isViaHub ? "Through Hub" : nil)
              }
            }
          }
          FormRow(
            "Folder", systemImage: "folder", hue: .orange,
            field: TextField("~/Developer/Atlas", text: $path)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .onSubmit(add))
        }
      }
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Open", action: add)
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(host == nil || trimmedPath.isEmpty || trimmedPath.hasSuffix("/"))
    }
    .onAppear { if hostID == nil { hostID = hosts.first?.id } }
  }

  private var trimmedPath: String { path.trimmingCharacters(in: .whitespaces) }

  private func add() {
    guard let host, !trimmedPath.isEmpty else { return }
    let saved = SavedRemote(hostID: host.id, path: trimmedPath)
    RemoteRepositories.add(saved)
    dismiss()
    added(saved)
  }
}

/// New Branch: from the current commit, checked out.
struct NewBranchSheet: View {
  let model: RepositoryModel
  @State private var name = ""
  @Environment(\.kitDismiss) private var dismiss

  var body: some View {
    KitSheet(
      title: "New Branch", meta: "From \(model.status?.branch ?? "HEAD")", systemImage: "arrow.triangle.branch",
      hue: .orange
    ) {
      FormCard {
        FormRow(
          "Name", systemImage: "arrow.triangle.branch", hue: .orange,
          field: TextField("feature/name", text: $name)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(create))
      }
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Create", action: create)
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(trimmed.isEmpty || trimmed.contains(" "))
    }
  }

  private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

  private func create() {
    guard !trimmed.isEmpty else { return }
    let name = trimmed
    dismiss()
    Task { await model.createBranch(name) }
  }
}

/// Settings: the kit's panes, rows pushed on iPhone and a sidebar on iPad. Who commits is the vault's Your Name, asked at
/// the first commit that needs it. `close`, where nothing pushed the screen: iPad's Done.
struct SettingsScreen: View {
  var close: (() -> Void)?
  @AppStorage("SettingsPane") private var pane = "GitHub"

  var body: some View {
    KitSettings(selection: $pane) {
      SettingsPane("GitHub", systemImage: "cloud", hue: .indigo) { GitHubSettingsView() }
      SettingsPane("Security", systemImage: "lock.shield", hue: .green) { SecuritySettingsPane() }
      SettingsPane("Privacy", systemImage: "hand.raised", hue: .blue) { PrivacySettingsPane() }
      SettingsPane("Devices", systemImage: "laptopcomputer", hue: .blue, section: "v57") { VaultDevicesSettings() }
    }
    .kitPane(.content)
    .kitToolbar("Settings", meta: ["Git"], systemImage: "gearshape", hue: .gray) {
      if let close { Button("Done", action: close).buttonStyle(.kitPrimary) }
    }
    .navigationBarBackButtonHidden(true)
  }
}
