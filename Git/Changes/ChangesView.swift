import GitKit
import SwiftUI

/// Changes: staged and unstaged files with the commit composer below them, and the selected
/// file's diff on the right.
struct ChangesScreen: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        ChangeList(session: session, state: state)
          .frame(maxHeight: .infinity)
        Divider()
        CommitComposer(session: session, state: state)
      }
      .frame(width: 360)
      Divider()
      ChangeDetailView(session: session, state: state)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

/// "Staged · 2" and "Unstaged · 3", each with its rows and Stage All / Unstage All.
private struct ChangeList: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  @State private var pendingDiscard: [FileChange] = []

  private var status: WorkingTreeStatus? { session.status }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if let status {
          sectionHeader("Staged", count: status.staged.count, action: "Unstage All") {
            Task { await session.unstageAll() }
          }
          if status.staged.isEmpty, !status.isClean {
            Text("Tick a file below to include it in the next commit.")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(12)
              .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(
                  .separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
              )
              .padding(.horizontal, 8)
              .padding(.bottom, 6)
          }
          ForEach(status.staged) { change in
            row(change).transition(.opacity.combined(with: .move(edge: .bottom)))
          }
          sectionHeader("Unstaged", count: status.unstaged.count, action: "Stage All") {
            Task { await session.stageAll() }
          }
          .padding(.top, 10)
          ForEach(status.unstaged) { change in
            row(change).transition(.opacity.combined(with: .move(edge: .top)))
          }
        } else {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .animation(.app, value: status)
    }
    .onChange(of: status, initial: true) { _, status in
      guard let status else { return }
      let all = status.staged + status.unstaged
      let ids = Set(all.map(\.id))
      var kept = state.selectedChanges.intersection(ids)
      if kept.isEmpty, let previous = state.selectedChanges.first {
        // Follow a file that moved between Staged and Unstaged.
        let path = previous.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        if let moved = all.first(where: { $0.path == path }) { kept = [moved.id] }
      }
      if kept.isEmpty, let first = all.first { kept = [first.id] }
      if kept != state.selectedChanges { state.selectedChanges = kept }
    }
    .confirmationDialog(
      discardTitle,
      isPresented: .init(get: { !pendingDiscard.isEmpty }, set: { if !$0 { pendingDiscard = [] } }),
      titleVisibility: .visible
    ) {
      Button("Discard Changes", role: .destructive) {
        let changes = pendingDiscard
        Task { await session.discard(changes) }
      }
    } message: {
      Text("Changes to tracked files are lost. New files are moved to the Trash.")
    }
  }

  private var discardTitle: String {
    pendingDiscard.count == 1
      ? "Discard changes to \(pendingDiscard[0].fileName)?"
      : "Discard changes to \(pendingDiscard.count) files?"
  }

  private func sectionHeader(
    _ title: String, count: Int, action: String, perform: @escaping () -> Void
  ) -> some View {
    HStack {
      Text("\(title) · \(count)")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .contentTransition(.numericText(value: Double(count)))
        .animation(.app, value: count)
      Spacer()
      if count > 0 {
        Button(action, action: perform)
          .buttonStyle(.borderless)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.accentColor)
          .disabled(session.isBusy)
      }
    }
    .padding(.horizontal, 8)
    .frame(height: 32)
  }

  private func row(_ change: FileChange) -> some View {
    ChangeRow(
      change: change, lines: session.lineCounts[change.id],
      isSelected: state.selectedChanges.contains(change.id)
    ) {
      Task {
        if change.area == .staged {
          await session.unstage([change])
        } else {
          await session.stage([change])
        }
      }
    } select: {
      state.selectedChanges = [change.id]
    }
    .contextMenu { contextMenu(for: change) }
  }

  @ViewBuilder
  private func contextMenu(for change: FileChange) -> some View {
    if change.area == .staged {
      Button("Unstage") { Task { await session.unstage([change]) } }
    } else {
      Button("Stage") { Task { await session.stage([change]) } }
      Button("Discard Changes…", role: .destructive) { pendingDiscard = [change] }
    }
    Divider()
    let url = session.repository.url.appendingPathComponent(change.path)
    Button("Open") { NSWorkspace.shared.open(url) }
    Button("Show in Finder") { RepositoryLibrary.reveal(url) }
    Button("Copy Path") { copyToPasteboard(change.path) }
  }
}

/// A changed file: checkbox, status, name over folder, and line counts.
private struct ChangeRow: View {
  let change: FileChange
  let lines: LineCounts?
  let isSelected: Bool
  let toggle: () -> Void
  let select: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Toggle("", isOn: .init(get: { change.area == .staged }, set: { _ in toggle() }))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .accessibilityLabel((change.area == .staged ? "Unstage " : "Stage ") + change.fileName)
      Button(action: select) {
        HStack(spacing: 8) {
          ChangeKindBadge(kind: change.kind)
          VStack(alignment: .leading, spacing: 1) {
            Text(change.fileName)
              .fontWeight(.medium)
              .lineLimit(1)
              .truncationMode(.middle)
            Text(change.originalPath.map { "from \($0)" } ?? change.directory)
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.head)
          }
          Spacer(minLength: 4)
          LineCountText(counts: lines)
        }
        .frame(height: 36)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
    .padding(.horizontal, 8)
    .background(
      isSelected ? Color.accentColor.opacity(0.14) : .clear,
      in: .rect(cornerRadius: 7, style: .continuous)
    )
    .animation(.app, value: isSelected)
    .help(change.path)
  }
}
