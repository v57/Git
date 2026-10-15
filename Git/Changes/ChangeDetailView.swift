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
        WorkingTreeClean(branch: session.status?.branch ?? "HEAD") { withAnimation(.kit) { state.mode = .history } }
          .transition(.page)
      } else if let change, let loaded, loaded.target == target {
        VStack(spacing: 0) {
          header(change, diff: loaded.diff)
          Divider()
          if loaded.diff.hunks.isEmpty {
            DiffPlaceholder(diff: loaded.diff)
          } else {
            DiffView(content: loaded, selection: $selection, changesOnly: true, cards: true) { hunk in
              hunkButtons(hunk, change: change, diff: loaded.diff)
            }
          }
        }
        .id(loaded.target)
        .transition(.page)
      } else if change != nil, !isLoading {
        ContentUnavailableView("No Changes", systemImage: "equal")
      } else if change == nil {
        ContentUnavailableView("No File Selected", systemImage: "doc.text")
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    .confirmationDialog(
      "Discard the selected lines?",
      isPresented: .init(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }),
      titleVisibility: .visible
    ) {
      Button("Discard Lines", role: .destructive) {
        if let lines = confirmDiscard, let diff = loaded?.diff {
          Task { await session.discardLines(lines, of: diff) }
          selection = []
        }
      }
    } message: {
      Text("The working-tree changes on these lines are lost.")
    }
    .confirmationDialog(
      "Discard changes to \(change?.fileName ?? "")?", isPresented: $confirmDiscardFile,
      titleVisibility: .visible
    ) {
      Button("Discard Changes", role: .destructive) {
        if let change { Task { await discardAll(change) } }
      }
    } message: {
      Text("Staged and unstaged changes to the file are lost. New files are moved to the Trash.")
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
      loaded = result?.spaced(by: 14)
    } catch {
      guard !Task.isCancelled else { return }
      loaded = nil
      session.report(error, title: "Couldn't load the diff")
    }
  }

  // MARK: Header and actions

  private func header(_ change: FileChange, diff: FileDiff) -> some View {
    HStack(spacing: 10) {
      ChangeKindBadge(kind: change.kind, size: 20)
      (Text(change.directory.isEmpty ? "" : change.directory + "/").foregroundStyle(.secondary)
        + Text(change.fileName).fontWeight(.semibold))
        .font(.system(size: 12.5, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.head)
        .textSelection(.enabled)
      LineCountText(
        counts: LineCounts(added: diff.additions, removed: diff.deletions),
        font: .system(size: 12, design: .monospaced))
      Spacer()
      if !selection.isEmpty, diff.supportsLineSelection {
        Text("\(selection.count) selected")
          .font(.caption)
          .foregroundStyle(.secondary)
        lineButtons(change: change, diff: diff)
      } else if diff.ignoresWhitespace {
        Text("Whitespace hidden: stage whole files")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Button("Discard…") { confirmDiscardFile = true }
        .buttonStyle(.design(.destructive))
      Button(change.area == .staged ? "Unstage File" : "Stage File") {
        Task {
          if change.area == .staged {
            await session.unstage([change])
          } else {
            await session.stage([change])
          }
        }
      }
      .buttonStyle(.design)
    }
    .disabled(session.isBusy)
    .padding(.horizontal, 20)
    .frame(height: 52)
  }

  @ViewBuilder
  private func lineButtons(change: FileChange, diff: FileDiff) -> some View {
    let lines = selection
    if change.area == .staged {
      Button("Unstage Lines") {
        Task { await session.unstageLines(lines, of: diff) }
        selection = []
      }
      .buttonStyle(.design)
    } else {
      Button("Discard Lines…") { confirmDiscard = lines }
        .buttonStyle(.design(.destructive))
      Button("Stage Lines") {
        Task { await session.stageLines(lines, of: diff) }
        selection = []
      }
      .buttonStyle(.design(.primary))
    }
  }

  @ViewBuilder
  private func hunkButtons(_ hunk: DiffHunk, change: FileChange, diff: FileDiff) -> some View {
    let lines = PatchBuilder.lines(in: hunk)
    if diff.supportsLineSelection {
      if change.area == .staged {
        Button("Unstage Hunk") { Task { await session.unstageLines(lines, of: diff) } }
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.accentColor)
      } else {
        Button("Stage Hunk") { Task { await session.stageLines(lines, of: diff) } }
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.accentColor)
          .contextMenu {
            Button("Discard Hunk…", role: .destructive) { confirmDiscard = lines }
          }
      }
    }
  }
}

/// Nothing to commit: a check mark and a way to History.
private struct WorkingTreeClean: View {
  let branch: String
  let showHistory: () -> Void
  @State private var appeared = false

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "checkmark")
        .font(.system(size: 26, weight: .semibold))
        .foregroundStyle(.green)
        .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
        .onAppear { appeared = true }
        .frame(width: 56, height: 56)
        .background(Color.green.opacity(0.15), in: .circle)
        .accessibilityHidden(true)
      Text("Working tree clean")
        .font(.system(size: 17, weight: .semibold))
        .padding(.top, 4)
      Text("Nothing left to commit on \(branch).")
        .foregroundStyle(.secondary)
      Button("View History", action: showHistory)
        .buttonStyle(.link)
        .fontWeight(.medium)
        .padding(.top, 6)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// "✓ Committed “…” to main" with Undo and Push.
private struct CommitToast: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  let message: String

  private var ahead: Int { session.status?.ahead ?? 0 }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "checkmark")
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(.green)
        .symbolEffect(.bounce, options: .nonRepeating, value: message)
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
          .buttonStyle(ToastButtonStyle(prominent: false))
          if session.remotes.isEmpty {
            Button("Publish…") { state.isPublishPresented = true }
              .buttonStyle(ToastButtonStyle(prominent: true))
          } else {
            Button(ahead > 0 ? "Push \(ahead)" : "Push") {
              Task {
                if await session.push() {
                  state.lastCommit = "Pushed to \(session.status?.upstream ?? "the remote")"
                }
              }
            }
            .buttonStyle(ToastButtonStyle(prominent: true))
          }
        }
      }
    }
    .foregroundStyle(.white)
    .padding(.leading, 14)
    .padding(.trailing, 8)
    .padding(.vertical, 8)
    .background(Color.black.opacity(0.85), in: .rect(cornerRadius: 14, style: .continuous))
    .shadow(color: .black.opacity(0.22), radius: 15, y: 10)
    .task(id: message) {
      // Hide after 20 seconds; a cancelled wait (the view was rebuilt) keeps the toast.
      do { try await Task.sleep(for: .seconds(20)) } catch { return }
      if state.lastCommit == message { state.lastCommit = nil }
    }
    .accessibilityElement(children: .contain)
  }
}

private struct ToastButtonStyle: ButtonStyle {
  let prominent: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .fontWeight(prominent ? .semibold : .medium)
      .padding(.horizontal, 12)
      .frame(height: 28)
      .background(
        prominent ? Color.accentColor : Color.white.opacity(0.14),
        in: .rect(cornerRadius: 8, style: .continuous)
      )
      .opacity(configuration.isPressed ? 0.75 : 1)
  }
}

/// Diff display options, set from the View menu.
enum DiffOptions {
  static let hideWhitespaceKey = "HideWhitespaceChanges"
}
