import GitKit
import SwiftUI

/// Branch picker, Fetch / Pull / Push, Stash, and activity.
struct RepositoryToolbar: ToolbarContent {
  let session: RepositorySession

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      BranchMenu(session: session)
    }
    ToolbarItemGroup(placement: .primaryAction) {
      if let activity = session.activity {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text(session.progress ?? activity.title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: 220, alignment: .leading)
        }
      }
      StashMenu(session: session)
      Button {
        Task { await session.fetch() }
      } label: {
        Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
      }
      .help("Fetch all remotes")
      .disabled(session.isBusy || session.remotes.isEmpty)
      Button {
        Task { await session.pull() }
      } label: {
        CountLabel(title: "Pull", systemImage: "arrow.down", count: session.status?.behind ?? 0)
      }
      .help("Pull from \(session.status?.upstream ?? "the upstream branch")")
      .disabled(session.isBusy || session.status?.upstream == nil)
      Button {
        Task { await session.push() }
      } label: {
        CountLabel(title: "Push", systemImage: "arrow.up", count: session.status?.ahead ?? 0)
      }
      .help(
        session.status?.upstream.map { "Push to \($0)" }
          ?? "Publish this branch to \(session.remotes.first ?? "a remote")")
      .disabled(session.isBusy || session.remotes.isEmpty || session.status?.branch == nil)
    }
  }
}

/// A toolbar label with a count next to the icon.
private struct CountLabel: View {
  let title: String
  let systemImage: String
  let count: Int

  var body: some View {
    Label {
      Text(title)
    } icon: {
      HStack(spacing: 2) {
        Image(systemName: systemImage)
        if count > 0 {
          Text("\(count)")
            .font(.caption.monospacedDigit())
        }
      }
    }
    .labelStyle(.titleAndIcon)
  }
}

private struct BranchMenu: View {
  let session: RepositorySession
  @State private var isCreating = false
  @State private var pendingDelete: Branch?

  private var title: String {
    guard let status = session.status else { return "—" }
    if let branch = status.branch { return branch }
    return status.headOID.map { "Detached at \($0.prefix(7))" } ?? "No Commits"
  }

  var body: some View {
    Menu {
      Button("New Branch…") { isCreating = true }
      Divider()
      Section("Branches") {
        ForEach(session.localBranches) { branch in
          Button {
            Task { await session.switchTo(branch) }
          } label: {
            branchLabel(branch)
          }
          .disabled(branch.isCurrent)
        }
      }
      if !session.remoteBranches.isEmpty {
        Menu("Remote Branches") {
          ForEach(session.remoteBranches) { branch in
            Button(branch.name) { Task { await session.switchTo(branch) } }
          }
        }
      }
      let deletable = session.localBranches.filter { !$0.isCurrent }
      if !deletable.isEmpty {
        Menu("Delete Branch") {
          ForEach(deletable) { branch in
            Button(branch.name) { pendingDelete = branch }
          }
        }
      }
    } label: {
      Label(title, systemImage: "arrow.triangle.branch")
        .labelStyle(.titleAndIcon)
    }
    .help("Switch or create a branch")
    .disabled(session.isBusy)
    .sheet(isPresented: $isCreating) {
      NewBranchSheet(session: session, startPoint: nil)
    }
    .confirmationDialog(
      "Delete \(pendingDelete?.name ?? "")?",
      isPresented: .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        if let branch = pendingDelete { Task { await session.deleteBranch(branch) } }
      }
      Button("Force Delete", role: .destructive) {
        if let branch = pendingDelete { Task { await session.deleteBranch(branch, force: true) } }
      }
    } message: {
      Text("Delete refuses a branch that isn't merged; Force Delete removes it anyway.")
    }
  }

  private func branchLabel(_ branch: Branch) -> some View {
    var text = branch.name
    if branch.ahead > 0 { text += "  ↑\(branch.ahead)" }
    if branch.behind > 0 { text += "  ↓\(branch.behind)" }
    if branch.isUpstreamGone { text += "  (upstream gone)" }
    return Label(text, systemImage: branch.isCurrent ? "checkmark" : "")
      .labelStyle(.titleAndIcon)
  }
}

private struct StashMenu: View {
  let session: RepositorySession
  @State private var isStashing = false
  @State private var pendingDrop: Stash?

  var body: some View {
    Menu {
      Button("Stash Changes…") { isStashing = true }
        .disabled(session.status?.isClean ?? true)
      if let latest = session.stashes.first {
        Button("Pop Latest Stash") { Task { await session.popStash(latest) } }
      }
      if !session.stashes.isEmpty {
        Divider()
        ForEach(session.stashes) { stash in
          Menu(stash.message) {
            Button("Apply") { Task { await session.applyStash(stash) } }
            Button("Pop") { Task { await session.popStash(stash) } }
            Divider()
            Button("Drop…", role: .destructive) { pendingDrop = stash }
          }
        }
      }
    } label: {
      CountLabel(title: "Stash", systemImage: "tray.and.arrow.down", count: session.stashes.count)
    }
    .help("Stash changes")
    .disabled(session.isBusy)
    .sheet(isPresented: $isStashing) {
      StashSheet(session: session)
    }
    .confirmationDialog(
      "Drop this stash?",
      isPresented: .init(get: { pendingDrop != nil }, set: { if !$0 { pendingDrop = nil } }),
      titleVisibility: .visible
    ) {
      Button("Drop", role: .destructive) {
        if let stash = pendingDrop { Task { await session.dropStash(stash) } }
      }
    } message: {
      Text(pendingDrop?.message ?? "")
    }
  }
}

private struct StashSheet: View {
  let session: RepositorySession
  @Environment(\.dismiss) private var dismiss
  @State private var message = ""
  @State private var includeUntracked = true

  var body: some View {
    Form {
      TextField("Message", text: $message, prompt: Text("Optional"))
      Toggle("Include untracked files", isOn: $includeUntracked)
    }
    .formStyle(.grouped)
    .frame(width: 380)
    .navigationTitle("Stash Changes")
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Stash") {
          let message = message
          let includeUntracked = includeUntracked
          Task { await session.stash(message: message, includeUntracked: includeUntracked) }
          dismiss()
        }
      }
    }
  }
}

/// Creates a branch at HEAD or `startPoint` and checks it out.
struct NewBranchSheet: View {
  let session: RepositorySession
  let startPoint: String?
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var checkout = true
  @State private var isValid = false

  var body: some View {
    Form {
      TextField("Name", text: $name, prompt: Text("feature/my-change"))
      if let startPoint {
        LabeledContent("From", value: String(startPoint.prefix(7)))
      } else {
        LabeledContent("From", value: session.status?.branch ?? "HEAD")
      }
      Toggle("Switch to the new branch", isOn: $checkout)
    }
    .formStyle(.grouped)
    .frame(width: 400)
    .navigationTitle("New Branch")
    .task(id: name) {
      let trimmed = name.trimmingCharacters(in: .whitespaces)
      isValid = await session.repository.isValidBranchName(trimmed)
        && !session.localBranches.contains { $0.name == trimmed }
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Create") {
          let name = name.trimmingCharacters(in: .whitespaces)
          let checkout = checkout
          Task { await session.createBranch(name, from: startPoint, checkout: checkout) }
          dismiss()
        }
        .disabled(!isValid)
      }
    }
  }
}

/// Opens `NewBranchSheet` from a menu (e.g. a commit's context menu).
struct NewBranchButton: View {
  let session: RepositorySession
  let startPoint: String
  let title: String
  @State private var isPresented = false

  var body: some View {
    Button(title) { isPresented = true }
      .sheet(isPresented: $isPresented) {
        NewBranchSheet(session: session, startPoint: startPoint)
      }
  }
}
