import GitKit
import SwiftUI

/// The diff of the selected change, with hunk and line actions for staging, unstaging and
/// discarding.
struct ChangeDetailView: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  @Environment(\.colorScheme) private var colorScheme
  @State private var loaded: LoadedDiff?
  @State private var isLoading = false
  @State private var selection: Set<Int> = []
  @State private var confirmDiscard: Set<Int>?

  private var selectedChanges: [FileChange] {
    guard let status = session.status else { return [] }
    return (status.conflicted + status.staged + status.unstaged)
      .filter { state.selectedChanges.contains($0.id) }
  }

  private var change: FileChange? {
    selectedChanges.count == 1 ? selectedChanges.first : nil
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
      if let change, change.area == .conflicted {
        ConflictView(session: session, change: change)
      } else if selectedChanges.count > 1 {
        MultipleSelectionView(session: session, changes: selectedChanges)
      } else if let change, let loaded, loaded.target == target {
        VStack(spacing: 0) {
          header(change, diff: loaded.diff)
          Divider()
          if loaded.diff.hunks.isEmpty {
            DiffPlaceholder(diff: loaded.diff)
          } else {
            DiffView(content: loaded, selection: $selection, changesOnly: true) { hunk in
              hunkButtons(hunk, change: change, diff: loaded.diff)
            }
          }
        }
      } else if change != nil, !isLoading {
        ContentUnavailableView("No Changes", systemImage: "equal")
      } else if change == nil {
        ContentUnavailableView("No File Selected", systemImage: "doc.text")
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: LoadKey(target: target, revision: session.revision, dark: colorScheme == .dark)) {
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
  }

  private struct LoadKey: Hashable {
    var target: DiffTarget?
    var revision: Int
    var dark: Bool
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
        target, repository: session.repository, isDark: colorScheme == .dark)
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
    HStack(spacing: 8) {
      ChangeKindBadge(kind: change.kind)
      Text(change.path)
        .lineLimit(1)
        .truncationMode(.head)
        .textSelection(.enabled)
      Text("+\(diff.additions) −\(diff.deletions)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      Spacer()
      if !selection.isEmpty {
        Text("\(selection.count) selected")
          .font(.caption)
          .foregroundStyle(.secondary)
        lineButtons(change: change, diff: diff)
      }
    }
    .controlSize(.small)
    .padding(.horizontal, 12)
    .frame(height: 36)
  }

  @ViewBuilder
  private func lineButtons(change: FileChange, diff: FileDiff) -> some View {
    let lines = selection
    if diff.supportsLineSelection {
      if change.area == .staged {
        Button("Unstage Lines") {
          Task { await session.unstageLines(lines, of: diff) }
          selection = []
        }
      } else {
        Button("Discard Lines…") { confirmDiscard = lines }
        Button("Stage Lines") {
          Task { await session.stageLines(lines, of: diff) }
          selection = []
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }

  @ViewBuilder
  private func hunkButtons(_ hunk: DiffHunk, change: FileChange, diff: FileDiff) -> some View {
    let lines = PatchBuilder.lines(in: hunk)
    if diff.supportsLineSelection {
      if change.area == .staged {
        Button("Unstage Hunk") { Task { await session.unstageLines(lines, of: diff) } }
      } else {
        Button("Discard Hunk…") { confirmDiscard = lines }
        Button("Stage Hunk") { Task { await session.stageLines(lines, of: diff) } }
      }
    }
  }
}

/// Several files selected: act on all of them at once.
private struct MultipleSelectionView: View {
  let session: RepositorySession
  let changes: [FileChange]

  var body: some View {
    ContentUnavailableView {
      Label("\(changes.count) Files Selected", systemImage: "doc.on.doc")
    } actions: {
      let unstaged = changes.filter { $0.area != .staged }
      let staged = changes.filter { $0.area == .staged }
      if !unstaged.isEmpty {
        Button("Stage \(unstaged.count)") { Task { await session.stage(unstaged) } }
      }
      if !staged.isEmpty {
        Button("Unstage \(staged.count)") { Task { await session.unstage(staged) } }
      }
    }
  }
}

/// A conflicted file: resolve it elsewhere, then mark it resolved.
private struct ConflictView: View {
  let session: RepositorySession
  let change: FileChange

  var body: some View {
    ContentUnavailableView {
      Label("Conflict in \(change.fileName)", systemImage: "exclamationmark.triangle")
    } description: {
      Text("Edit the file to resolve the conflict markers, then mark it as resolved.")
    } actions: {
      Button("Open") {
        NSWorkspace.shared.open(session.repository.url.appendingPathComponent(change.path))
      }
      Button("Mark as Resolved") { Task { await session.stage([change]) } }
        .buttonStyle(.borderedProminent)
    }
  }
}
