import GitKit
import SwiftData
import SwiftUI

/// The window toolbar for a repository, as in the design: Fetch, Pull and Push (with the number
/// of commits to push), then Branch, Merge and Stash. While conflicts are being resolved it shows
/// the keyboard shortcuts instead.
struct RepositoryToolbar: ToolbarContent {
  let session: RepositorySession
  let state: RepositoryViewState
  let screen: RepositoryScreenKind

  var body: some ToolbarContent {
    if screen == .conflicts {
      ToolbarItem(placement: .primaryAction) {
        Text("⌥⌘← Use Current · ⌥⌘→ Use Incoming")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
      }
    } else {
      ToolbarItemGroup(placement: .primaryAction) {
        SyncButtons(session: session, state: state)
      }
      // Sets Fetch, Pull and Push apart from Branch, Merge and Stash.
      if #available(macOS 26, *) {
        ToolbarSpacer(.fixed, placement: .primaryAction)
      }
      ToolbarItemGroup(placement: .primaryAction) {
        BranchToolbarButton(session: session)
        if screen == .history {
          MergeMenu(session: session)
        }
        StashMenu(session: session)
      }
    }
  }
}

/// Which screen the detail area shows; the toolbar and title follow it.
enum RepositoryScreenKind: Equatable {
  case changes, history, stashes, conflicts
}

/// Fetch, Pull and Push.
private struct SyncButtons: View {
  let session: RepositorySession
  let state: RepositoryViewState
  @State private var confirmForcePush = false

  private var ahead: Int { session.status?.ahead ?? 0 }
  private var hasUpstream: Bool { session.status?.upstream != nil }

  var body: some View {
    Button {
      Task { await session.fetch() }
    } label: {
      Label(session.activity == .fetching ? "Fetching…" : "Fetch", systemImage: "arrow.clockwise")
        .labelStyle(.titleAndIcon)
        .contentTransition(.interpolate)
        .symbolEffect(.rotate, isActive: session.activity == .fetching)
    }
    .disabled(session.remotes.isEmpty || session.isBusy)
    .help(fetchHelp)
    Button {
      Task { await session.pull() }
    } label: {
      Label(session.activity == .pulling ? "Pulling…" : "Pull", systemImage: "arrow.down.to.line")
        .labelStyle(.titleAndIcon)
        .contentTransition(.interpolate)
        .symbolEffect(.pulse, isActive: session.activity == .pulling)
    }
    .disabled(!hasUpstream || session.isBusy)
    .help(hasUpstream ? "Pull from \(session.status?.upstream ?? "")" : "This branch has no upstream")
    Button {
      // Without a remote, Publish creates one on GitHub first.
      if session.remotes.isEmpty {
        state.isPublishPresented = true
      } else {
        Task { await session.push() }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "arrow.up.to.line")
          .symbolEffect(.pulse, isActive: session.activity == .pushing)
        Text(session.activity == .pushing ? "Pushing…" : hasUpstream ? "Push" : "Publish")
          .contentTransition(.interpolate)
        if ahead > 0 {
          Text("\(ahead)")
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            .contentTransition(.numericText(value: Double(ahead)))
            .transition(.scale.combined(with: .opacity))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.accentColor, in: .capsule)
        }
      }
      .fontWeight(ahead > 0 ? .semibold : .regular)
      .animation(.app, value: ahead)
      .animation(.app, value: session.activity)
    }
    .disabled(session.status?.branch == nil || session.headCommit == nil || session.isBusy)
    .help(pushHelp)
    .contextMenu {
      Button("Force Push…") { confirmForcePush = true }
        .disabled(!hasUpstream)
    }
    .confirmationDialog(
      "Force push \(session.status?.branch ?? "")?", isPresented: $confirmForcePush,
      titleVisibility: .visible
    ) {
      Button("Force Push", role: .destructive) { Task { await session.push(force: true) } }
    } message: {
      Text(
        "Replaces \(session.status?.upstream ?? "the remote branch") with your branch. It refuses "
          + "if someone else pushed since your last fetch.")
    }
  }

  private var pushHelp: String {
    let branch = session.status?.branch ?? "this branch"
    if session.headCommit == nil { return "Commit something first" }
    if session.remotes.isEmpty { return "Create a repository on GitHub and push \(branch) to it" }
    if !hasUpstream { return "Push \(branch) and track it" }
    return ahead > 0 ? "Push \(ahead) commit\(ahead == 1 ? "" : "s")" : "Push"
  }

  private var fetchHelp: String {
    if let progress = session.progress { return progress }
    if session.remotes.isEmpty { return "This repository has no remote" }
    guard let date = session.lastFetched else { return "Never fetched" }
    return "Last fetched \(date.formatted(.relative(presentation: .named)))"
  }
}

/// Branch: switch, create, merge or delete branches in a popover.
private struct BranchToolbarButton: View {
  let session: RepositorySession
  @State private var isPresented = launchArgument("--show-branches")

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      Label("Branch", systemImage: "arrow.triangle.branch")
        .labelStyle(.titleAndIcon)
    }
    .help("Switch or create a branch")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      BranchPopover(session: session, isPresented: $isPresented)
    }
  }
}

/// Merge: a branch into the current one.
private struct MergeMenu: View {
  let session: RepositorySession

  var body: some View {
    let current = session.currentBranch?.name ?? "HEAD"
    let candidates = session.localBranches.filter { !$0.isCurrent }
    Menu {
      Section("Merge into \(current)") {
        ForEach(candidates) { branch in
          Button(branch.name) { Task { await session.merge(branch) } }
            .disabled((branch.aheadOfHead ?? 1) == 0)
        }
      }
      let remotes = session.remoteBranches
      if !remotes.isEmpty {
        Section("Remote Branches") {
          ForEach(remotes) { branch in
            Button(branch.name) { Task { await session.merge(branch) } }
          }
        }
      }
    } label: {
      Label("Merge", systemImage: "arrow.triangle.merge")
        .labelStyle(.titleAndIcon)
    }
    .menuIndicator(.hidden)
    .disabled(session.isBusy || session.status?.branch == nil)
    .help("Merge a branch into \(current)")
  }
}

/// Debug builds open a popover at launch with `--show-branches`, for screenshots.
private func launchArgument(_ name: String) -> Bool {
  #if DEBUG
    ProcessInfo.processInfo.arguments.contains(name)
  #else
    false
  #endif
}

/// "3 ahead of main", "2 behind main" or "3 ahead, 2 behind main"; `nil` when level.
func divergenceText(ahead: Int?, behind: Int?, base: String) -> String? {
  let ahead = ahead ?? 0
  let behind = behind ?? 0
  switch (ahead > 0, behind > 0) {
  case (true, true): return "\(ahead) ahead, \(behind) behind \(base)"
  case (true, false): return "\(ahead) ahead of \(base)"
  case (false, true): return "\(behind) behind \(base)"
  case (false, false): return nil
  }
}

// MARK: - Branch popover

struct BranchPopover: View {
  let session: RepositorySession
  @Binding var isPresented: Bool
  @Environment(RepositoryLibrary.self) private var library
  @Environment(\.modelContext) private var context
  @State private var filter = ""
  @State private var isCreating = false
  @State private var pendingDelete: Branch?

  private var current: String { session.currentBranch?.name ?? "HEAD" }

  private func matches(_ branch: Branch) -> Bool {
    filter.isEmpty || branch.name.localizedCaseInsensitiveContains(filter)
  }

  private var localBranches: [Branch] {
    // Current first, then branches ahead of it, then the rest by name.
    session.localBranches.filter(matches).sorted { lhs, rhs in
      if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
      let lhsAhead = (lhs.aheadOfHead ?? 0) > 0
      let rhsAhead = (rhs.aheadOfHead ?? 0) > 0
      if lhsAhead != rhsAhead { return lhsAhead }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }

  private var remoteBranches: [Branch] {
    let local = Set(session.localBranches.map(\.name))
    return session.remoteBranches.filter { matches($0) && !local.contains($0.localName) }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        FilterField(text: $filter, prompt: "Filter branches")
        Button("New Branch…") { isCreating = true }
      }
      .padding(10)
      Divider()
      List {
        Section("Branches") {
          ForEach(localBranches) { branch in
            row(branch)
          }
        }
        if !remoteBranches.isEmpty {
          Section("Remote Branches") {
            ForEach(remoteBranches) { branch in
              row(branch)
            }
          }
        }
      }
      .listStyle(.inset)
    }
    .frame(width: 400, height: 440)
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

  private func row(_ branch: Branch) -> some View {
    let worktree = session.worktree(for: branch)
    let divergence = divergenceText(
      ahead: branch.aheadOfHead, behind: branch.behindHead, base: current)
    return Button {
      if let worktree {
        // A branch checked out in another worktree can't be checked out here; open that one.
        library.open(worktree.url, into: context)
      } else if !branch.isCurrent {
        Task { await session.switchTo(branch) }
      }
      isPresented = false
    } label: {
      HStack(spacing: 8) {
        Image(systemName: branch.isCurrent ? "checkmark" : worktree != nil ? "folder" : "arrow.triangle.branch")
          .foregroundStyle(branch.isCurrent ? Color.accentColor : .secondary)
          .frame(width: 16)
        VStack(alignment: .leading, spacing: 1) {
          Text(branch.name).lineLimit(1).truncationMode(.middle)
          HStack(spacing: 6) {
            if branch.isCurrent {
              Text("Current")
            } else if let divergence {
              Text(divergence)
                .foregroundStyle((branch.aheadOfHead ?? 0) > 0 ? Color.orange : .secondary)
            } else if branch.aheadOfHead == 0 {
              Text("Merged into \(current)")
            }
            if let worktree { Text("· in \(worktree.name)") }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        UpstreamBadge(branch: branch)
        if let date = branch.date {
          Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      if !branch.isCurrent, !branch.isRemote {
        Button("Merge into \(current)") {
          Task { await session.merge(branch) }
          isPresented = false
        }
        .disabled((branch.aheadOfHead ?? 1) == 0)
        Button("Delete…", role: .destructive) { pendingDelete = branch }
          .disabled(worktree != nil)
      }
      Button("Copy Name") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(branch.name, forType: .string)
      }
    }
  }
}

/// ↑/↓ against the branch's own upstream.
private struct UpstreamBadge: View {
  let branch: Branch

  var body: some View {
    if branch.isUpstreamGone {
      Image(systemName: "icloud.slash")
        .foregroundStyle(.secondary)
        .help("The upstream branch was deleted")
    } else if branch.ahead > 0 || branch.behind > 0 {
      HStack(spacing: 3) {
        if branch.behind > 0 { Text("↓\(branch.behind)") }
        if branch.ahead > 0 { Text("↑\(branch.ahead)") }
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .help("Against \(branch.upstream ?? "its upstream")")
    }
  }
}

// MARK: - Stash

struct StashMenu: View {
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
      Label("Stash", systemImage: "archivebox")
        .labelStyle(.titleAndIcon)
    }
    .menuIndicator(.hidden)
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

// MARK: - Sheets

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
      LabeledContent(
        "From", value: startPoint.map { String($0.prefix(7)) } ?? session.status?.branch ?? "HEAD")
      Toggle("Switch to the new branch", isOn: $checkout)
    }
    .formStyle(.grouped)
    .frame(width: 400)
    .navigationTitle("New Branch")
    .task(id: name) {
      let trimmed = name.trimmingCharacters(in: .whitespaces)
      isValid =
        await session.repository.isValidBranchName(trimmed)
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

/// Creates a tag at a commit, annotated when a message is given.
struct NewTagSheet: View {
  let session: RepositorySession
  let commit: Commit
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var message = ""
  @State private var isValid = false

  var body: some View {
    Form {
      TextField("Name", text: $name, prompt: Text("v1.0.0"))
      TextField("Message", text: $message, prompt: Text("Optional, makes an annotated tag"))
      LabeledContent("Commit", value: "\(commit.shortID) \(commit.subject)")
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .navigationTitle("New Tag")
    .task(id: name) {
      let trimmed = name.trimmingCharacters(in: .whitespaces)
      isValid = await session.repository.isValidTagName(trimmed)
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Create") {
          let name = name.trimmingCharacters(in: .whitespaces)
          let message = message
          Task { await session.createTag(name, at: commit, message: message) }
          dismiss()
        }
        .disabled(!isValid)
      }
    }
  }
}

// MARK: - Shared controls

/// A rounded filter field with a clear button.
struct FilterField: View {
  @Binding var text: String
  let prompt: String

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "line.3.horizontal.decrease")
        .foregroundStyle(.secondary)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 5)
    .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
  }
}
