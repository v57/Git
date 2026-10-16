import ComponentKit
import GitKit
import SwiftData
import SwiftUI

/// The window toolbar for a repository, as in the design: the screen's live title, then Fetch,
/// Pull and Push (with the number of commits to push) and Branch, Merge and Stash as tool cards.
/// While conflicts are being resolved it shows the keyboard shortcuts instead.
struct RepositoryToolbar: ToolbarContent {
  let session: RepositorySession
  let state: RepositoryViewState
  let screen: RepositoryScreenKind
  let title: String
  let meta: [String]
  /// History's search text, which shows the search field.
  let search: Binding<String>?

  var body: some ToolbarContent {
    PlainToolbarItem(placement: .navigation) {
      KitTitle(title, meta: meta, systemImage: titleImage, hue: titleHue, status: session.isBusy ? .working : .idle)
        .padding(.leading, 6)
    }
    if screen == .conflicts {
      PlainToolbarItem(placement: .primaryAction) {
        ToolGroup {
          Button {} label: { ShortcutLabel(keys: "⌥⌘←", title: "Use Current") }
          Button {} label: { ShortcutLabel(keys: "⌥⌘→", title: "Use Incoming") }
        }
        .allowsHitTesting(false)
      }
    } else {
      PlainToolbarItem(placement: .primaryAction) {
        HStack(spacing: KitMetrics.gutter) {
          ToolGroup { SyncButtons(session: session, state: state) }
          ToolGroup {
            BranchToolbarButton(session: session)
            if screen == .history {
              MergeMenu(session: session)
            }
            StashMenu(session: session)
          }
          if let search {
            KitSearchField(
              text: search, prompt: "Message, author, hash",
              status: session.isLoadingCommits && !search.wrappedValue.isEmpty ? .working : .idle
            )
            .frame(width: 240)
          }
        }
      }
    }
  }

  /// The screen's glyph, or the running operation's while one runs.
  private var titleImage: String {
    switch session.activity {
    case .fetching: return "arrow.clockwise"
    case .pulling: return "arrow.down.to.line"
    case .pushing: return "arrow.up.to.line"
    case .committing: return "checkmark"
    case .some: break
    case nil: break
    }
    switch screen {
    case .changes: return "pencil"
    case .history: return "clock"
    case .stashes: return "archivebox"
    case .conflicts: return "arrow.triangle.merge"
    }
  }

  private var titleHue: Hue {
    switch screen {
    case .changes: .orange
    case .history: .blue
    case .stashes: .indigo
    case .conflicts: .red
    }
  }
}

/// A toolbar item drawn by the kit alone: without the shared glass behind it (macOS 26).
struct PlainToolbarItem<Content: View>: ToolbarContent {
  let placement: ToolbarItemPlacement
  @ViewBuilder let content: () -> Content

  var body: some ToolbarContent {
    if #available(macOS 26, *) {
      ToolbarItem(placement: placement) { content() }
        .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: placement) { content() }
    }
  }
}

/// A shortcut's keys and what it does, for the conflict screen's toolbar.
private struct ShortcutLabel: View {
  let keys: String
  let title: String

  var body: some View {
    HStack(spacing: 6) {
      Keycaps(keys)
      Text(title).kitFont(.caption)
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
    Button(session.activity == .fetching ? "Fetching…" : "Fetch", systemImage: "arrow.clockwise") {
      Task { await session.fetch() }
    }
    .disabled(session.remotes.isEmpty || session.isBusy)
    .help(fetchHelp)
    Button(session.activity == .pulling ? "Pulling…" : "Pull", systemImage: "arrow.down.to.line") {
      Task { await session.pull() }
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
      Label {
        HStack(spacing: 5) {
          Text(session.activity == .pushing ? "Pushing…" : hasUpstream ? "Push" : "Publish")
          if ahead > 0 { Count(ahead, .attention).transition(.opacity) }
        }
      } icon: {
        Image(systemName: "arrow.up.to.line")
      }
      .animation(.kit, value: ahead)
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
    Button("Branch", systemImage: "arrow.triangle.branch") { isPresented.toggle() }
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
    }
    .disabled(session.isBusy || session.status?.branch == nil)
    .help("Merge a branch into \(current)")
  }
}

/// Debug builds open a popover at launch (or in a screenshot scene) with `--show-branches`, for screenshots.
private func launchArgument(_ name: String) -> Bool {
  #if DEBUG
    LaunchScene.shared.flag(name)
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
    .branchDeletion($pendingDelete, session: session)
  }

  private func row(_ branch: Branch) -> some View {
    let worktree = session.worktree(for: branch)
    let divergence = divergenceText(
      ahead: branch.aheadOfHead, behind: branch.behindHead, base: current)
    let isDeleting = session.deletingBranches.contains(branch.id)
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
            if isDeleting {
              ProgressView().controlSize(.mini)
              Text("Deleting…")
            } else if branch.isCurrent {
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
    .disabled(isDeleting)
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

// MARK: - Sheets

/// Creates a branch at HEAD or `startPoint` and checks it out.
struct NewBranchSheet: View {
  let session: RepositorySession
  let startPoint: String?
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var checkout = true
  @State private var isValid = false

  private let suggestedName = "feature/my-change"

  var body: some View {
    Form {
      TextField("Name", text: $name, prompt: Text(suggestedName))
        .onKeyPress(.tab) {
          guard name.isEmpty else { return .ignored }
          name = suggestedName
          return .handled
        }
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

extension View {
  func branchDeletion(_ pending: Binding<Branch?>, session: RepositorySession) -> some View {
    modifier(BranchDeletion(session: session, pending: pending))
  }
}

private struct BranchDeletion: ViewModifier {
  struct Everywhere: Identifiable {
    let branch: Branch
    let upstream: Branch
    var id: String { branch.id }
  }

  let session: RepositorySession
  @Binding var pending: Branch?
  @State private var everywhere: Everywhere?

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        "Delete \(pending?.name ?? "")?",
        isPresented: .init(get: { pending != nil }, set: { if !$0 { pending = nil } }),
        titleVisibility: .visible, presenting: pending
      ) { branch in
        Button("Delete", role: .destructive) { Task { await session.deleteBranch(branch) } }
        Button("Force Delete", role: .destructive) {
          Task { await session.deleteBranch(branch, force: true) }
        }
        if let upstream = session.upstream(of: branch) {
          Button("Delete Local and \(upstream.remoteName ?? "Remote")…", role: .destructive) {
            everywhere = Everywhere(branch: branch, upstream: upstream)
          }
        }
      } message: { branch in
        if let upstream = session.upstream(of: branch) {
          Text(
            "Delete refuses a branch that isn't merged; Force Delete removes it anyway. "
              + "Delete Local and \(upstream.remoteName ?? "Remote") also deletes \(upstream.name).")
        } else {
          Text("Delete refuses a branch that isn't merged; Force Delete removes it anyway.")
        }
      }
      .sheet(item: $everywhere) { item in
        DeleteEverywhereSheet(session: session, branch: item.branch, upstream: item.upstream)
      }
  }
}

private struct DeleteEverywhereSheet: View {
  let session: RepositorySession
  let branch: Branch
  let upstream: Branch
  @Environment(\.dismiss) private var dismiss
  @State private var confirmation = ""

  private var remote: String { upstream.remoteName ?? "the remote" }

  private var isConfirmed: Bool {
    confirmation.trimmingCharacters(in: .whitespaces) == branch.name
  }

  private var warnings: [String] {
    func commits(_ count: Int, on name: String, notOn other: String) -> String {
      count == 1
        ? "1 commit on \(name) isn't on \(other)." : "\(count) commits on \(name) aren't on \(other)."
    }
    var warnings: [String] = []
    if let ahead = branch.aheadOfHead, ahead > 0 {
      warnings.append(commits(ahead, on: branch.name, notOn: session.currentBranch?.name ?? "HEAD"))
    }
    if branch.behind > 0 {
      warnings.append(commits(branch.behind, on: upstream.name, notOn: branch.name))
    }
    return warnings
  }

  var body: some View {
    Form {
      Section {
        LabeledContent("Local", value: branch.name)
        LabeledContent("On \(remote)", value: upstream.name)
      } footer: {
        Text(
          "\(upstream.name) is deleted for everyone who uses \(remote), and only if nobody pushed "
            + "to it since you last fetched.")
      }
      if !warnings.isEmpty {
        Section {
          ForEach(warnings, id: \.self) { warning in
            Label {
              Text(warning)
            } icon: {
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
          }
        }
      }
      Section {
        TextField("Branch name", text: $confirmation, prompt: Text(branch.name))
          .labelsHidden()
      } header: {
        HStack(spacing: 0) {
          Text("Type ")
          Text(branch.name)
          Text(" to confirm")
        }
        .textSelection(.enabled)
      }
    }
    .formStyle(.grouped)
    .frame(width: 440)
    .navigationTitle("Delete Local and \(remote)")
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Delete", role: .destructive) {
          Task { await session.deleteBranch(branch, andUpstream: upstream) }
          dismiss()
        }
        .disabled(!isConfirmed)
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
