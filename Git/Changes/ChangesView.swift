import GitKit
import SwiftUI

/// Conflicted, staged and unstaged files with the commit composer below.
struct ChangesView: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  @State private var pendingDiscard: [FileChange] = []

  private var status: WorkingTreeStatus? { session.status }

  var body: some View {
    VStack(spacing: 0) {
      if let operation = status?.operation {
        OperationBanner(session: session, operation: operation)
        Divider()
      }
      if let status, !status.isClean {
        list(status)
      } else if status != nil {
        ContentUnavailableView(
          "No Changes", systemImage: "checkmark.circle",
          description: Text("The working tree matches HEAD."))
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      CommitComposer(session: session, state: state)
    }
    .confirmationDialog(
      discardTitle, isPresented: .init(
        get: { !pendingDiscard.isEmpty }, set: { if !$0 { pendingDiscard = [] } }),
      titleVisibility: .visible
    ) {
      Button("Discard Changes", role: .destructive) {
        let changes = pendingDiscard
        Task { await session.discard(changes) }
      }
    } message: {
      Text("Changes to tracked files are lost. Untracked files are moved to the Trash.")
    }
  }

  private var discardTitle: String {
    pendingDiscard.count == 1
      ? "Discard changes to \(pendingDiscard[0].fileName)?"
      : "Discard changes to \(pendingDiscard.count) files?"
  }

  private func list(_ status: WorkingTreeStatus) -> some View {
    List(selection: $state.selectedChanges) {
      if !status.conflicted.isEmpty {
        Section("Conflicts") {
          ForEach(status.conflicted) { change in
            ChangeRow(change: change) {
              Task { await session.stage([change]) }
            }
          }
        }
      }
      if !status.staged.isEmpty {
        Section {
          ForEach(status.staged) { change in
            ChangeRow(change: change) { Task { await session.unstage([change]) } }
          }
        } header: {
          SectionHeader(title: "Staged", count: status.staged.count, action: "Unstage All") {
            Task { await session.unstageAll() }
          }
        }
      }
      if !status.unstaged.isEmpty {
        Section {
          ForEach(status.unstaged) { change in
            ChangeRow(change: change) { Task { await session.stage([change]) } }
          }
        } header: {
          SectionHeader(title: "Changes", count: status.unstaged.count, action: "Stage All") {
            Task { await session.stageAll() }
          }
        }
      }
    }
    .contextMenu(forSelectionType: FileChange.ID.self) { ids in
      contextMenu(for: changes(ids, in: status))
    } primaryAction: { ids in
      // Double-click toggles staging.
      let selected = changes(ids, in: status)
      Task {
        await session.stage(selected.filter { $0.area != .staged })
        await session.unstage(selected.filter { $0.area == .staged })
      }
    }
    .onChange(of: status) { _, status in
      // Drop selections for files that are gone; follow a file that moved between areas.
      let ids = Set((status.staged + status.unstaged + status.conflicted).map(\.id))
      let kept = state.selectedChanges.intersection(ids)
      if kept.isEmpty, let previous = state.selectedChanges.first {
        let path = previous.split(separator: ":", maxSplits: 1).last.map(String.init)
        if let moved = ids.first(where: { $0.hasSuffix(":" + (path ?? "")) }) {
          state.selectedChanges = [moved]
          return
        }
      }
      if kept != state.selectedChanges { state.selectedChanges = kept }
    }
  }

  private func changes(_ ids: Set<FileChange.ID>, in status: WorkingTreeStatus) -> [FileChange] {
    (status.conflicted + status.staged + status.unstaged).filter { ids.contains($0.id) }
  }

  @ViewBuilder
  private func contextMenu(for changes: [FileChange]) -> some View {
    let staged = changes.filter { $0.area == .staged }
    let unstaged = changes.filter { $0.area != .staged }
    if !unstaged.isEmpty {
      Button(changes.contains { $0.area == .conflicted } ? "Mark as Resolved" : "Stage") {
        Task { await session.stage(unstaged) }
      }
    }
    if !staged.isEmpty {
      Button("Unstage") { Task { await session.unstage(staged) } }
    }
    let discardable = changes.filter { $0.area == .unstaged }
    if !discardable.isEmpty {
      Button("Discard Changes…", role: .destructive) { pendingDiscard = discardable }
    }
    if changes.count == 1, let change = changes.first {
      Divider()
      let url = session.repository.url.appendingPathComponent(change.path)
      Button("Open") { NSWorkspace.shared.open(url) }
      Button("Show in Finder") { RepositoryLibrary.reveal(url) }
      Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(change.path, forType: .string)
      }
    }
  }
}

private struct SectionHeader: View {
  let title: String
  let count: Int
  let action: String
  let perform: () -> Void

  var body: some View {
    HStack {
      Text("\(title) (\(count))")
      Spacer()
      Button(action, action: perform)
        .buttonStyle(.borderless)
        .font(.caption)
    }
  }
}

/// A changed file with a checkbox that stages or unstages it.
struct ChangeRow: View {
  let change: FileChange
  let toggle: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      if change.area != .conflicted {
        Toggle(
          "", isOn: .init(get: { change.area == .staged }, set: { _ in toggle() })
        )
        .toggleStyle(.checkbox)
        .labelsHidden()
        .help(change.area == .staged ? "Unstage" : "Stage")
      }
      ChangeKindBadge(kind: change.kind)
      VStack(alignment: .leading, spacing: 0) {
        Text(change.fileName)
          .lineLimit(1)
          .truncationMode(.middle)
        if let original = change.originalPath {
          Text("from \(original)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        } else if !change.directory.isEmpty {
          Text(change.directory)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        }
      }
    }
    .help(change.path)
  }
}

struct ChangeKindBadge: View {
  let kind: ChangeKind

  var body: some View {
    Text(kind.letter)
      .font(.system(size: 10, weight: .bold, design: .monospaced))
      .foregroundStyle(.white)
      .frame(width: 16, height: 16)
      .background(color, in: .rect(cornerRadius: 4))
      .help(kind.rawValue.capitalized)
  }

  private var color: Color {
    switch kind {
    case .added, .untracked: .green
    case .modified, .typeChanged: .orange
    case .deleted: .red
    case .renamed, .copied: .blue
    case .conflicted: .purple
    }
  }
}

/// Shown while a merge, rebase, cherry-pick or revert waits to be continued or aborted.
private struct OperationBanner: View {
  let session: RepositorySession
  let operation: RepositoryOperation

  var body: some View {
    HStack {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading) {
        Text(operation.title).bold()
        Text(
          session.status?.conflicted.isEmpty == false
            ? "Resolve the conflicts and stage the files, then continue."
            : "Ready to continue."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Abort") { Task { await session.abortOperation() } }
      Button("Continue") { Task { await session.continueOperation() } }
        .disabled(session.status?.conflicted.isEmpty == false)
    }
    .controlSize(.small)
    .padding(10)
    .background(.orange.opacity(0.1))
  }
}
