import ComponentKit
import GitKit
import SwiftData
import SwiftUI

/// The repository's toolbar, the kit's own: the screen's live title, then Fetch, Pull and Push
/// (with the number of commits to push) and Branch, Merge and Stash as tool cards, which go
/// icon-only when the window narrows. While conflicts are being resolved it shows the keyboard
/// shortcuts instead.
struct RepositoryToolbar {
  let session: RepositorySession
  let state: RepositoryViewState
  let screen: RepositoryScreenKind
  let title: String
  let meta: [String]
  /// History's search text, which shows the search field.
  let search: Binding<String>?

  var titleView: KitTitle {
    KitTitle(title, meta: meta, systemImage: titleImage, hue: titleHue, status: session.workStatus)
  }

  @ToolbarSlotBuilder var tools: [ToolbarSlot] {
    if screen == .conflicts {
      ToolGroup {
        Button {} label: { ShortcutLabel(keys: "⌥⌘←", title: "Use Current") }
        Button {} label: { ShortcutLabel(keys: "⌥⌘→", title: "Use Incoming") }
      }
      .allowsHitTesting(false)
    } else {
      ToolGroup { SyncButtons(session: session, state: state) }
      ToolGroup {
        BranchToolbarButton(session: session, state: state)
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

extension RepositorySession {
  /// The live icon's state: working while anything runs, with the transfer's share once a fetch,
  /// pull or push reports one.
  var workStatus: WorkStatus {
    guard isBusy else { return .idle }
    return .working(progress: progress.flatMap(GitProgress.fraction))
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

/// Fetch, Pull and Push. Each plays the kit's effect when it lands: a sweep of light for a fetch,
/// a drop for a pull, a send for a push, a shake when it fails.
private struct SyncButtons: View {
  @Environment(RepositoryLibrary.self) private var library
  let session: RepositorySession
  let state: RepositoryViewState
  @State private var confirmForcePush = false
  @State private var fetched = 0
  @State private var pulled = 0
  @State private var pushed = 0
  @State private var failed = 0

  /// Until the repository's first load is in, what the sidebar already knows about it, so the buttons don't start
  /// out disabled.
  private var summary: RepositorySummary? {
    session.revision == 0 ? library.summaries[session.repository.url.path] : nil
  }
  private var ahead: Int { session.status?.ahead ?? summary?.ahead ?? 0 }
  private var hasUpstream: Bool { session.status.map { $0.upstream != nil } ?? summary?.hasUpstream ?? false }
  private var hasRemote: Bool { summary.map(\.hasUpstream) ?? !session.remotes.isEmpty }
  private var canPush: Bool {
    summary.map { $0.branch != nil && $0.headOID != nil } ?? (session.status?.branch != nil && session.headCommit != nil)
  }

  var body: some View {
    Button(session.activity == .fetching ? "Fetching…" : "Fetch", systemImage: "arrow.clockwise") {
      Task { await count(session.fetch(), into: $fetched) }
    }
    .disabled(!hasRemote || session.isBusy)
    .help(fetchHelp)
    .effect(.shimmer, on: fetched)
    Button(session.activity == .pulling ? "Pulling…" : "Pull", systemImage: "arrow.down.to.line") {
      Task { await count(session.pull(), into: $pulled) }
    }
    .disabled(!hasUpstream || session.isBusy)
    .help(hasUpstream ? "Pull from \(session.status?.upstream ?? "")" : "This branch has no upstream")
    .effect(.receive("arrow.down.circle.fill"), on: pulled)
    Button {
      // Without a remote, Publish creates one on GitHub first.
      if !hasRemote {
        state.isPublishPresented = true
      } else {
        Task { await count(session.push(), into: $pushed) }
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
    .disabled(!canPush || session.isBusy)
    .help(pushHelp)
    .effect(.send("arrow.up.circle.fill"), on: pushed)
    .kitContextMenu {
      Button("Force Push…", systemImage: "exclamationmark.arrow.triangle.2.circlepath") { confirmForcePush = true }
        .disabled(!hasUpstream || session.isBusy)
    }
    .effect(.failure, on: failed)
    .kitConfirmation(
      "Force push \(session.status?.branch ?? "")?", isPresented: $confirmForcePush,
      message: "Replaces \(session.status?.upstream ?? "the remote branch") with your branch. It refuses "
        + "if someone else pushed since your last fetch.",
      systemImage: "arrow.up.to.line", confirm: "Force Push"
    ) {
      Task { await count(session.push(force: true), into: $pushed) }
    }
  }

  /// Counts a finished fetch, pull or push, so its effect plays (or the failure's).
  private func count(_ succeeded: Bool, into counter: Binding<Int>) {
    if succeeded { counter.wrappedValue += 1 } else { failed += 1 }
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
  @Bindable var state: RepositoryViewState

  var body: some View {
    Button("Branch", systemImage: "arrow.triangle.branch") { state.isBranchPopoverPresented.toggle() }
    .help("Switch or create a branch")
    .popover(isPresented: $state.isBranchPopoverPresented, arrowEdge: .bottom) {
      BranchPopover(session: session, isPresented: $state.isBranchPopoverPresented)
    }
  }
}

/// Merge: a branch into the current one, from the kit's menu.
private struct MergeMenu: View {
  let session: RepositorySession
  @State private var isPresented = false

  var body: some View {
    let current = session.currentBranch?.name ?? "HEAD"
    Button("Merge", systemImage: "arrow.triangle.merge") { isPresented.toggle() }
      .disabled(session.isBusy || session.status?.branch == nil)
      .help("Merge a branch into \(current)")
      .kitMenu(isPresented: $isPresented) {
        KitMenuSection("Merge into \(current)") {
          ForEach(session.localBranches.filter { !$0.isCurrent }) { branch in
            Button(branch.name, systemImage: "arrow.triangle.branch") { Task { await session.merge(branch) } }
              .disabled((branch.aheadOfHead ?? 1) == 0)
          }
        }
        let remotes = session.remoteBranches
        if !remotes.isEmpty {
          Divider()
          KitMenuSection("Remote Branches") {
            ForEach(remotes) { branch in
              Button(branch.name, systemImage: "cloud") { Task { await session.merge(branch) } }
            }
          }
        }
      }
  }
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
      HStack(spacing: KitMetrics.gutter) {
        KitSearchField(text: $filter, prompt: "Filter branches")
        Button("New Branch…") { isCreating = true }
          .buttonStyle(.kit)
      }
      .padding(10)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          sectionTitle("Branches")
          ForEach(localBranches) { branch in
            row(branch)
          }
          if !remoteBranches.isEmpty {
            sectionTitle("Remote Branches")
            ForEach(remoteBranches) { branch in
              row(branch)
            }
          }
        }
        .padding([.horizontal, .bottom], 10)
      }
    }
    .frame(width: 400, height: 440)
    .background(.kitPanel)
    .sheet(isPresented: $isCreating) {
      NewBranchSheet(session: session, startPoint: nil)
    }
    .branchDeletion($pendingDelete, session: session)
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title)
      .kitFont(.sectionHeader)
      .padding(.horizontal, 8)
      .padding(.top, 8)
      .padding(.bottom, 4)
  }

  private func row(_ branch: Branch) -> some View {
    let worktree = session.worktree(for: branch)
    let divergence = divergenceText(
      ahead: branch.aheadOfHead, behind: branch.behindHead, base: current)
    let isDeleting = session.deletingBranches.contains(branch.id)
    return BranchRow {
      if let worktree {
        // A branch checked out in another worktree can't be checked out here; open that one.
        library.open(worktree.url, into: context)
      } else if !branch.isCurrent {
        Task { await session.switchTo(branch) }
      }
      isPresented = false
    } content: {
      HStack(spacing: 8) {
        Image(systemName: branch.isCurrent ? "checkmark" : worktree != nil ? "folder" : "arrow.triangle.branch")
          .foregroundStyle(branch.isCurrent ? AnyShapeStyle(.kitAccent) : AnyShapeStyle(.kitSecondary))
          .frame(width: 16)
        VStack(alignment: .leading, spacing: 1) {
          Text(branch.name).lineLimit(1).truncationMode(.middle)
          HStack(spacing: 4) {
            if isDeleting {
              LiveIcon(systemImage: "trash", hue: .gray, status: .working, size: 12)
              Text("Deleting…")
            } else if branch.isCurrent {
              Text("Current")
            } else if let divergence {
              Text(divergence)
                .foregroundStyle((branch.aheadOfHead ?? 0) > 0 ? AnyShapeStyle(Hue.orange.text) : AnyShapeStyle(.kitSecondary))
            } else if branch.aheadOfHead == 0 {
              Text("Merged into \(current)")
            }
            if let worktree { Text("· in \(worktree.name)") }
          }
          .kitFont(.caption)
        }
        Spacer(minLength: 4)
        UpstreamBadge(branch: branch)
        if let date = branch.date {
          Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
            .kitFont(.caption)
            .foregroundStyle(.kitTertiary)
        }
      }
    }
    .disabled(isDeleting)
    .kitContextMenu {
      if !branch.isCurrent, !branch.isRemote {
        Button("Merge into \(current)", systemImage: "arrow.triangle.merge") {
          Task { await session.merge(branch) }
          isPresented = false
        }
        .disabled((branch.aheadOfHead ?? 1) == 0)
        Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = branch }
          .disabled(worktree != nil)
        Divider()
      }
      Button("Copy Name", systemImage: "doc.on.doc") { KitPasteboard.copy(branch.name) }
    }
  }
}

/// ↑/↓ against the branch's own upstream.
private struct UpstreamBadge: View {
  let branch: Branch

  var body: some View {
    if branch.isUpstreamGone {
      Image(systemName: "icloud.slash")
        .foregroundStyle(.kitSecondary)
        .help("The upstream branch was deleted")
    } else if branch.ahead > 0 || branch.behind > 0 {
      SyncCounts(ahead: branch.ahead, behind: branch.behind)
        .help("Against \(branch.upstream ?? "its upstream")")
    }
  }
}

// MARK: - Stash

/// Stash: put the changes aside, pop the latest, or apply, pop or drop any stash from its submenu.
struct StashMenu: View {
  let session: RepositorySession
  @State private var isPresented = false
  @State private var isStashing = false
  @State private var pendingDrop: Stash?

  var body: some View {
    Button("Stash", systemImage: "archivebox") { isPresented.toggle() }
      .help("Stash changes")
      .disabled(session.isBusy)
      .kitMenu(isPresented: $isPresented) {
        Button("Stash Changes…", systemImage: "archivebox") { isStashing = true }
          .disabled(session.status?.isClean ?? true)
        if let latest = session.stashes.first {
          Button("Pop Latest Stash", systemImage: "tray.and.arrow.up") { Task { await session.popStash(latest) } }
        }
        if !session.stashes.isEmpty {
          Divider()
          ForEach(session.stashes) { stash in
            KitSubmenu(stash.message) {
              Button("Apply") { Task { await session.applyStash(stash) } }
              Button("Pop") { Task { await session.popStash(stash) } }
              Divider()
              Button("Drop…", role: .destructive) { pendingDrop = stash }
            }
          }
        }
      }
      .sheet(isPresented: $isStashing) {
        StashSheet(session: session)
      }
      .kitConfirmation(
        "Drop this stash?",
        isPresented: .init(get: { pendingDrop != nil }, set: { if !$0 { pendingDrop = nil } }),
        message: pendingDrop?.message, systemImage: "trash", confirm: "Drop"
      ) {
        if let stash = pendingDrop { Task { await session.dropStash(stash) } }
      }
  }
}

private struct StashSheet: View {
  let session: RepositorySession
  @Environment(\.dismiss) private var dismiss
  @State private var message = ""
  @State private var includeUntracked = true

  var body: some View {
    KitSheet(
      title: "Stash Changes", meta: "Puts your uncommitted changes aside, so you can switch branches.",
      systemImage: "archivebox", hue: .indigo
    ) {
      FormCard {
        FormRow("Message", help: "Optional", systemImage: "text.alignleft", field: TextField("WIP on \(session.status?.branch ?? "HEAD")", text: $message))
        FormRow("Include untracked files", help: "New files go into the stash too", systemImage: "doc.badge.plus", hue: .teal) {
          Toggle("Include untracked files", isOn: $includeUntracked).toggleStyle(.kitSwitch).kitLabelsHidden()
        }
      }
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Stash") {
        let message = message
        let includeUntracked = includeUntracked
        Task { await session.stash(message: message, includeUntracked: includeUntracked) }
        dismiss()
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
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
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    KitSheet(
      title: "New Branch", meta: "From \(startPoint.map { String($0.prefix(7)) } ?? session.status?.branch ?? "HEAD")",
      systemImage: "arrow.triangle.branch", hue: .orange
    ) {
      FormCard {
        FormRow(
          "Name", help: "Tab fills in \(suggestedName)", systemImage: "character.cursor.ibeam",
          error: !trimmed.isEmpty && !isValid ? "Not a valid or free branch name" : nil,
          field: TextField(suggestedName, text: $name)
            .onKeyPress(.tab) {
              guard name.isEmpty else { return .ignored }
              name = suggestedName
              return .handled
            })
        FormRow("Switch to the new branch", systemImage: "arrow.right.circle", hue: .blue) {
          Toggle("Switch to the new branch", isOn: $checkout).toggleStyle(.kitSwitch).kitLabelsHidden()
        }
      }
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Create") {
        let checkout = checkout
        Task { await session.createBranch(trimmed, from: startPoint, checkout: checkout) }
        dismiss()
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
      .disabled(!isValid)
    }
    .task(id: name) {
      isValid =
        await session.repository.isValidBranchName(trimmed)
        && !session.localBranches.contains { $0.name == trimmed }
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
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    KitSheet(title: "New Tag", meta: "\(commit.shortID) \(commit.subject)", systemImage: "tag", hue: .gray) {
      FormCard {
        FormRow(
          "Name", systemImage: "character.cursor.ibeam",
          error: !trimmed.isEmpty && !isValid ? "Not a valid tag name" : nil,
          field: TextField("v1.0.0", text: $name))
        FormRow(
          "Message", help: "Optional, makes an annotated tag", systemImage: "text.alignleft",
          field: TextField("Release notes", text: $message))
      }
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Create") {
        let message = message
        Task { await session.createTag(trimmed, at: commit, message: message) }
        dismiss()
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
      .disabled(!isValid)
    }
    .task(id: name) {
      isValid = await session.repository.isValidTagName(trimmed)
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
  /// The branch last asked about, so the sheet keeps its text while it closes.
  @State private var asked: Branch?

  private var branch: Branch? { pending ?? asked }

  func body(content: Content) -> some View {
    content
      .onChange(of: pending) { if let pending { asked = pending } }
      .kitConfirmation(
        "Delete \(branch?.name ?? "")?",
        isPresented: .init(get: { pending != nil }, set: { if !$0 { pending = nil } }),
        message: message, systemImage: "trash", buttons: buttons)
      .sheet(item: $everywhere) { item in
        DeleteEverywhereSheet(session: session, branch: item.branch, upstream: item.upstream)
      }
  }

  /// Delete Local and Remote… (with an upstream), Force Delete, and Delete, which Return presses.
  private var buttons: [KitConfirmationButton] {
    guard let branch else { return [] }
    var buttons: [KitConfirmationButton] = []
    if let upstream = session.upstream(of: branch) {
      // AppKit queues this sheet until the confirmation's is gone.
      buttons.append(
        KitConfirmationButton("Delete Local and \(upstream.remoteName ?? "Remote")…", role: .destructive) {
          everywhere = Everywhere(branch: branch, upstream: upstream)
        })
    }
    buttons.append(
      KitConfirmationButton("Force Delete", role: .destructive) {
        Task { await session.deleteBranch(branch, force: true) }
      })
    buttons.append(
      KitConfirmationButton("Delete", role: .destructive, isDefault: true) {
        Task { await session.deleteBranch(branch) }
      })
    return buttons
  }

  private var message: String {
    let message = "Delete refuses a branch that isn't merged; Force Delete removes it anyway."
    guard let branch, let upstream = session.upstream(of: branch) else { return message }
    return message + " Delete Local and \(upstream.remoteName ?? "Remote") also deletes \(upstream.name)."
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
    KitSheet(
      title: "Delete Local and \(remote)",
      meta: "\(upstream.name) is deleted for everyone who uses \(remote), and only if nobody pushed to it since you last fetched.",
      systemImage: "trash", hue: .red
    ) {
      FormCard {
        FormRow("Local", help: branch.name, systemImage: "arrow.triangle.branch", hue: .orange)
        FormRow("On \(remote)", help: upstream.name, systemImage: "cloud", hue: .blue)
        ForEach(warnings, id: \.self) { warning in
          FormRow(warning, systemImage: "exclamationmark.triangle", hue: .orange)
        }
      }
      FormCard {
        FormRow(
          "Type \(branch.name) to confirm", systemImage: "character.cursor.ibeam", hue: .red,
          field: TextField(branch.name, text: $confirmation))
      }
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Delete", role: .destructive) {
        Task { await session.deleteBranch(branch, andUpstream: upstream) }
        dismiss()
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
      .disabled(!isConfirmed)
    }
  }
}

/// A row of the Branch popover: hover fills it, a click acts on it.
private struct BranchRow<Content: View>: View {
  let action: () -> Void
  @ViewBuilder let content: () -> Content
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 8) { content() }
      .padding(.horizontal, 8)
      .frame(minHeight: 44)
      .background {
        if isHovered { RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous).fill(.kitHover) }
      }
      .contentShape(Rectangle())
      .onTapGesture(perform: action)
      .onHover { isHovered = $0 }
      .animation(.kitFast, value: isHovered)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isButton)
  }
}
