import ComponentKit
import GitKit
import SwiftUI

/// The diff of the selected change: a header with Discard and Stage File, and each hunk as a
/// card with Stage Hunk. Lines can be selected to stage, unstage or discard just them. After a
/// commit, a toast offers Undo and Push.
struct ChangeDetailView: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  @Environment(\.colorScheme) private var colorScheme
  @State private var loaded: LoadedDiff?
  @State private var isLoading = false
  @State private var selection: Set<Int> = []
  @State private var confirmDiscard: Set<Int>?
  @State private var confirmDiscardFile = false
  @AppStorage(DiffOptions.hideWhitespaceKey) private var hideWhitespace = false

  private var change: FileChange? {
    guard let status = session.status, let id = state.selectedChanges.first else { return nil }
    return (status.staged + status.unstaged).first { $0.id == id }
  }

  private var target: DiffTarget? {
    guard let change else { return nil }
    switch change.area {
    case .staged: return .staged(path: change.path, originalPath: change.originalPath)
    case .unstaged, .conflicted:
      return .unstaged(path: change.path, untracked: change.kind == .untracked)
    }
  }

  var body: some View {
    Group {
      if session.status?.isClean == true {
        EmptyState(
          systemImage: "checkmark", title: "Working tree clean",
          message: "Nothing left to commit on \(session.status?.branch ?? "HEAD")."
        ) {
          Button("View History") { withKitAnimation { state.mode = .history } }.buttonStyle(.kit)
        }
        .transition(.page)
      } else if let change, let loaded, loaded.target == target {
        VStack(spacing: 0) {
          header(change, diff: loaded.diff)
          if loaded.diff.hunks.isEmpty {
            DiffPlaceholder(diff: loaded.diff)
          } else {
            ScrollView {
              HunkCards(content: loaded, mode: hunkMode(change, diff: loaded.diff), selection: $selection)
                .padding([.horizontal, .bottom], KitMetrics.gutter)
                .padding(.bottom, 72)
            }
          }
        }
        .id(loaded.target)
        .transition(.page)
      } else if change != nil, !isLoading {
        EmptyState(systemImage: "equal", title: "No Changes")
      } else if change == nil {
        EmptyState(systemImage: "doc.text", title: "No File Selected", message: "Pick a file to see its changes.")
      } else {
        LiveIcon(systemImage: "doc.text", hue: .gray, status: .working)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .kitPane(.secondary)
    .overlay(alignment: .bottom) {
      if let message = state.lastCommit {
        CommitToast(session: session, state: state, message: message)
          .padding(.bottom, 24)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.kit, value: state.lastCommit)
    .animation(.kit, value: loaded?.target)
    .animation(.kit, value: session.status?.isClean)
    .task(
      id: LoadKey(
        target: target, revision: session.revision, dark: colorScheme == .dark,
        hideWhitespace: hideWhitespace)
    ) {
      await load()
    }
    .onChange(of: target) { selection = [] }
    .kitConfirmation(
      "Discard the selected lines?",
      isPresented: .init(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }),
      message: "The working-tree changes on these lines are lost.", systemImage: "trash",
      confirm: "Discard Lines"
    ) {
      if let lines = confirmDiscard, let diff = loaded?.diff {
        Task { await session.discardLines(lines, of: diff) }
        selection = []
      }
    }
    .kitConfirmation(
      "Discard changes to \(change?.fileName ?? "")?", isPresented: $confirmDiscardFile,
      message: "Staged and unstaged changes to the file are lost. New files are moved to the Trash.",
      systemImage: "trash", confirm: "Discard Changes"
    ) {
      if let change { Task { await discardAll(change) } }
    }
  }

  /// Discards a file's staged and unstaged changes.
  private func discardAll(_ change: FileChange) async {
    if change.area == .staged {
      await session.discardStaged([change])
    } else {
      await session.discard([change])
    }
  }

  private struct LoadKey: Hashable {
    var target: DiffTarget?
    var revision: Int
    var dark: Bool
    var hideWhitespace: Bool
  }

  private func load() async {
    guard let target else {
      loaded = nil
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      let result = try await LoadedDiff.load(
        target, repository: session.repository, isDark: colorScheme == .dark,
        ignoreWhitespace: hideWhitespace)
      guard !Task.isCancelled else { return }
      if result?.diff != loaded?.diff { selection = [] }
      loaded = result
    } catch {
      guard !Task.isCancelled else { return }
      loaded = nil
      session.report(error, title: "Couldn't load the diff")
    }
  }

  // MARK: Header and actions

  private func header(_ change: FileChange, diff: FileDiff) -> some View {
    HStack(spacing: 10) {
      ChangeKindBadge(kind: change.kind)
      (Text(change.directory.isEmpty ? "" : change.directory + "/").foregroundStyle(.kitSecondary)
        + Text(change.fileName))
        .kitFont(.mono)
        .lineLimit(1)
        .truncationMode(.head)
        .textSelection(.enabled)
      Diffstat(added: diff.additions, removed: diff.deletions)
      Spacer()
      if !selection.isEmpty, diff.supportsLineSelection {
        Count(selection.count == 1 ? "1 line" : "\(selection.count) lines")
        lineButtons(change: change, diff: diff)
      } else if diff.ignoresWhitespace {
        Text("Whitespace hidden: stage whole files").kitFont(.caption)
      }
      Button("Discard…", role: .destructive) { confirmDiscardFile = true }
        .buttonStyle(.kit)
      Button(change.area == .staged ? "Unstage File" : "Stage File") {
        Task {
          if change.area == .staged {
            await session.unstage([change])
          } else {
            await session.stage([change])
          }
        }
      }
      .buttonStyle(.kit)
    }
    .disabled(session.isBusy)
    .padding(.horizontal, 14)
    .frame(height: 52)
  }

  /// Discard Lines for unstaged lines; the hunk cards stage and unstage the selected lines themselves.
  @ViewBuilder
  private func lineButtons(change: FileChange, diff: FileDiff) -> some View {
    if change.area != .staged {
      let lines = selection
      Button("Discard Lines…", role: .destructive) { confirmDiscard = lines }
        .buttonStyle(.kit)
    }
  }

  /// What the hunk cards offer: staging lines and hunks, or unstaging staged hunks.
  private func hunkMode(_ change: FileChange, diff: FileDiff) -> HunkCards.Mode {
    guard diff.supportsLineSelection else { return .readOnly }
    if change.area == .staged {
      return .staged(unstage: { lines in Task { await session.unstageLines(lines, of: diff) } })
    }
    return .unstaged(
      stage: { lines in Task { await session.stageLines(lines, of: diff) } },
      discard: { lines in confirmDiscard = lines })
  }
}

/// "✓ Committed “…” to main" with Undo and Push.
private struct CommitToast: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  let message: String

  private var ahead: Int { session.status?.ahead ?? 0 }

  var body: some View {
    HStack(spacing: 10) {
      LiveIcon(systemImage: "checkmark", hue: .green, status: .done, size: 24)
      Text(message)
        .lineLimit(1)
        .contentTransition(.interpolate)
      if !message.hasPrefix("Committed and pushed") {
        HStack(spacing: 6) {
          Button("Undo") {
            Task {
              guard let undone = await session.undoLastCommit() else { return }
              if state.summary.isEmpty && state.details.isEmpty {
                let parts = undone.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                state.summary = parts.first.map(String.init) ?? ""
                state.details = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
              }
              state.lastCommit = nil
            }
          }
          .buttonStyle(.kitPlain)
          if session.remotes.isEmpty {
            Button("Publish…") { state.isPublishPresented = true }
              .buttonStyle(.kitPrimary)
          } else {
            Button(ahead > 0 ? "Push \(ahead)" : "Push") {
              Task {
                if await session.push() {
                  state.lastCommit = "Pushed to \(session.status?.upstream ?? "the remote")"
                }
              }
            }
            .buttonStyle(.kitPrimary)
          }
        }
      }
    }
    .controlSize(.small)
    .padding(.leading, 8)
    .padding(.trailing, 6)
    .padding(.vertical, 6)
    .kitSurface(.floating, cornerRadius: KitMetrics.radiusXL)
    .task(id: message) {
      // Hide after 20 seconds; a cancelled wait (the view was rebuilt) keeps the toast.
      do { try await Task.sleep(for: .seconds(20)) } catch { return }
      if state.lastCommit == message { state.lastCommit = nil }
    }
    .accessibilityElement(children: .contain)
  }
}

/// Diff display options, set from the View menu.
enum DiffOptions {
  static let hideWhitespaceKey = "HideWhitespaceChanges"
}
