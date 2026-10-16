import ComponentKit
import GitKit
import SwiftUI

/// Changes: staged and unstaged files with the commit composer below them, and the selected
/// file's diff on the right.
struct ChangesScreen: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState

  var body: some View {
    ResizableSplit(
      "ChangesListWidth", pane: .leading, width: 360, range: 280...640, mainMinWidth: 360
    ) {
      ChangeDetailView(session: session, state: state)
        .frame(maxHeight: .infinity)
    } pane: {
      VStack(spacing: 0) {
        ChangeList(session: session, state: state)
          .frame(maxHeight: .infinity)
        CommitComposer(session: session, state: state)
      }
      .kitPane(.secondary)
    }
  }
}

/// "Staged · 2" and "Unstaged · 3", each with its rows, Discard All and Stage All / Unstage All.
private struct ChangeList: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  @State private var pendingDiscard: PendingDiscard?

  /// Changes waiting for the user to confirm discarding them, all from one area.
  private struct PendingDiscard {
    var changes: [FileChange]
    var area: ChangeArea
  }

  private var status: WorkingTreeStatus? { session.status }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: KitMetrics.gutter) {
        if let status {
          let stagedLines = lines(status.staged)
          ChangeCard(
            title: "Staged", systemImage: "tray", hue: .green,
            meta: fileCount(status.staged.count), lines: stagedLines,
            action: "Unstage All", isBusy: session.isBusy, isEmpty: status.staged.isEmpty
          ) {
            Task { await session.unstageAll() }
          } discard: {
            pendingDiscard = PendingDiscard(changes: status.staged, area: .staged)
          } rows: {
            if status.staged.isEmpty, !status.isClean {
              Text("Tick a file below to include it in the next commit.")
                .kitFont(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
            }
            ForEach(status.staged) { change in
              row(change).transition(.row)
            }
          }
          ChangeCard(
            title: "Unstaged", systemImage: "pencil", hue: .orange,
            meta: fileCount(status.unstaged.count), lines: lines(status.unstaged),
            action: "Stage All", isBusy: session.isBusy, isEmpty: status.unstaged.isEmpty
          ) {
            Task { await session.stageAll() }
          } discard: {
            pendingDiscard = PendingDiscard(changes: status.unstaged, area: .unstaged)
          } rows: {
            ForEach(status.unstaged) { change in
              row(change).transition(.row)
            }
          }
        } else {
          LiveIcon(systemImage: "pencil", hue: .gray, status: .working)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
      }
      .padding(KitMetrics.gutter)
      .animation(.kit, value: status)
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
    .kitConfirmation(
      discardTitle,
      isPresented: .init(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
      message: discardMessage, systemImage: "trash", confirm: "Discard Changes"
    ) {
      if let pending = pendingDiscard {
        Task {
          if pending.area == .staged {
            await session.discardStaged(pending.changes)
          } else {
            await session.discard(pending.changes)
          }
        }
      }
    }
  }

  private var discardMessage: String {
    guard let pending = pendingDiscard else { return "" }
    let files = pending.changes.count == 1 ? "the file" : "these files"
    return pending.area == .staged
      ? "Staged and unstaged changes to \(files) are lost. New files are moved to the Trash."
      : "Unstaged changes are lost; staged changes are kept. New files are moved to the Trash."
  }

  private func fileCount(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }

  /// The lines a list of changes adds and removes, `nil` while they're counted.
  private func lines(_ changes: [FileChange]) -> (added: Int, removed: Int)? {
    let counts = changes.compactMap { session.lineCounts[$0.id] }
    guard !changes.isEmpty, !counts.isEmpty else { return nil }
    return (counts.compactMap(\.added).reduce(0, +), counts.compactMap(\.removed).reduce(0, +))
  }

  private var discardTitle: String {
    guard let pending = pendingDiscard else { return "" }
    let area = pending.area == .staged ? "staged" : "unstaged"
    return pending.changes.count == 1
      ? "Discard changes to \(pending.changes[0].fileName)?"
      : "Discard \(area) changes to \(pending.changes.count) files?"
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
    }
    Button("Discard Changes…", role: .destructive) {
      pendingDiscard = PendingDiscard(changes: [change], area: change.area)
    }
    Divider()
    let url = session.repository.url.appendingPathComponent(change.path)
    Button("Open") { NSWorkspace.shared.open(url) }
    Button("Show in Finder") { RepositoryLibrary.reveal(url) }
    Button("Copy Path") { KitPasteboard.copy(change.path) }
  }
}

/// Staged or Unstaged: a card whose header sums up its files, with Discard All and Stage All
/// (or Unstage All), then its rows, laid out lazily.
private struct ChangeCard<Rows: View>: View {
  let title: String
  let systemImage: String
  let hue: Hue
  let meta: String
  let lines: (added: Int, removed: Int)?
  let action: String
  let isBusy: Bool
  let isEmpty: Bool
  let perform: () -> Void
  let discard: () -> Void
  @ViewBuilder let rows: () -> Rows

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      RichHeader(
        Text(title),
        icon: { Tile(systemImage: systemImage, hue: hue, size: 24) },
        meta: {
          HStack(spacing: 6) {
            Text(meta)
            if let lines {
              Text("·").foregroundStyle(.kitTertiary)
              Diffstat(added: lines.added, removed: lines.removed)
            }
          }
        },
        accessory: {
          if !isEmpty {
            HStack(spacing: 2) {
              Button("Discard All…", systemImage: "trash", action: discard)
                .help("Discard all \(title.lowercased()) changes")
              Button(action, action: perform)
                .buttonStyle(.kitPlain)
            }
            .disabled(isBusy)
          }
        }
      )
      .padding([.horizontal, .top], KitMetrics.cardPadding)
      LazyVStack(spacing: 2) { rows() }
        .padding([.horizontal, .bottom], KitMetrics.cardPadding)
    }
    .kitSurface(.card)
  }
}

/// A changed file: checkbox, status, name over folder, and line counts.
private struct ChangeRow: View {
  let change: FileChange
  let lines: GitKit.LineCounts?
  let isSelected: Bool
  let toggle: () -> Void
  let select: () -> Void
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 8) {
      Toggle(
        (change.area == .staged ? "Unstage " : "Stage ") + change.fileName,
        isOn: .init(get: { change.area == .staged }, set: { _ in toggle() })
      )
      .toggleStyle(.kitCheckbox)
      .kitLabelsHidden()
      .fixedSize()
      ChangeKindBadge(kind: change.kind)
      VStack(alignment: .leading, spacing: 1) {
        Text(change.fileName)
          .fontWeight(isSelected ? .medium : .regular)
          .lineLimit(1)
          .truncationMode(.middle)
        if let folder = change.originalPath.map({ "from \($0)" }) ?? (change.directory.isEmpty ? nil : change.directory) {
          Text(folder)
            .kitFont(.caption)
            .lineLimit(1)
            .truncationMode(.head)
        }
      }
      Spacer(minLength: 4)
      if let lines {
        Diffstat(added: lines.added, removed: lines.removed)
      }
    }
    .padding(.horizontal, 6)
    .frame(height: 40)
    .background {
      if isSelected {
        Color.clear.kitSurface(.raised, cornerRadius: KitMetrics.radius)
      } else if isHovered {
        RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous).fill(.kitHover)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: select)
    .onHover { isHovered = $0 }
    .animation(.kit, value: isSelected)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .help(change.path)
  }
}
