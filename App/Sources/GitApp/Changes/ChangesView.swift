import ComponentKit
import GitKit
import GitUI
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
  /// What the rows do, filled as the list updates (`ChangeRowActions`).
  @State private var rowActions = ChangeRowActions()

  /// Changes waiting for the user to confirm discarding them, all from one area.
  private struct PendingDiscard {
    var changes: [FileChange]
    var area: ChangeArea
  }

  private var status: WorkingTreeStatus? { session.status }

  var body: some View {
    let actions = rowActions.configured(
      toggle: { change in
        Task {
          if change.area == .staged {
            await session.unstage([change])
          } else {
            await session.stage([change])
          }
        }
      },
      select: { state.selectedChanges = [$0.id] },
      menu: { AnyView(contextMenu(for: $0)) })
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
              row(change, actions: actions).transition(.row)
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
              row(change, actions: actions).transition(.row)
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

  private var discardMessage: LocalizedStringKey {
    guard let pending = pendingDiscard else { return "" }
    switch (pending.area == .staged, pending.changes.count == 1) {
    case (true, true): return "Staged and unstaged changes to the file are lost. New files are moved to the Trash."
    case (true, false): return "Staged and unstaged changes to these files are lost. New files are moved to the Trash."
    case (false, _): return "Unstaged changes are lost; staged changes are kept. New files are moved to the Trash."
    }
  }

  private func fileCount(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }

  /// The lines a list of changes adds and removes, `nil` while they're counted.
  private func lines(_ changes: [FileChange]) -> (added: Int, removed: Int)? {
    let counts = changes.compactMap { session.lineCounts[$0.id] }
    guard !changes.isEmpty, !counts.isEmpty else { return nil }
    return (counts.compactMap(\.added).reduce(0, +), counts.compactMap(\.removed).reduce(0, +))
  }

  private var discardTitle: LocalizedStringKey {
    guard let pending = pendingDiscard else { return "" }
    if pending.changes.count == 1 { return "Discard changes to \(pending.changes[0].fileName)?" }
    return pending.area == .staged
      ? "Discard staged changes to \(pending.changes.count) files?"
      : "Discard unstaged changes to \(pending.changes.count) files?"
  }

  /// The row takes the actions box rather than closures, so picking another file builds only the two rows it changes.
  private func row(_ change: FileChange, actions: ChangeRowActions) -> some View {
    ChangeRow(
      change: change, lines: session.lineCounts[change.id],
      isSelected: state.selectedChanges.contains(change.id), actions: actions
    )
    .equatable()
    .modifier(ChangeRowMenu(change: change, actions: actions))
  }

  @ViewBuilder
  private func contextMenu(for change: FileChange) -> some View {
    if change.area == .staged {
      Button("Unstage", systemImage: "minus.circle") { Task { await session.unstage([change]) } }
        .kitMenuPreview("Takes \(change.fileName) out of the next commit. Your changes stay.")
    } else {
      Button("Stage", systemImage: "plus.circle") { Task { await session.stage([change]) } }
        .kitMenuPreview("Puts \(change.fileName) in the next commit.")
    }
    if change.kind != .deleted, change.path != ".gitignore" {
      ignoreMenu(for: change)
    }
    Button("Discard Changes…", systemImage: "trash", role: .destructive) {
      pendingDiscard = PendingDiscard(changes: [change], area: change.area)
    }
    .kitMenuPreview(discardPreview(change))
    Divider()
    FileOpenItems(repository: session.repository, path: change.path)
  }

  /// What Discard Changes… does to one file, as `discard` and `discardStaged` do it: tracked files go back to the index
  /// (unstaged) or the last commit (staged), new files to the Trash.
  private func discardPreview(_ change: FileChange) -> String {
    let name = change.fileName
    if change.kind == .untracked || (change.area == .staged && change.kind == .added) {
      return String(localized: "Moves \(name) to the Trash. It asks first.")
    }
    let lines = session.lineCounts[change.id].map { ($0.added ?? 0) + ($0.removed ?? 0) } ?? 0
    let these = lines > 0 ? String(localized: "these \(counted(lines, .changedLine))") : String(localized: "the changes")
    return change.area == .staged
      ? String(localized: "Removes \(these) and puts \(name) back as it was in the last commit, unstaged changes too. It asks first; you can’t undo this.")
      : String(localized: "Removes \(these) from \(name); what you staged stays. It asks first; you can’t undo this.")
  }

  /// Add to .gitignore: the file itself, or a submenu that also offers its extension and folders.
  @ViewBuilder
  private func ignoreMenu(for change: FileChange) -> some View {
    let patterns = Repository.ignorePatterns(for: change.path)
    let ignore = { (pattern: String) in Task { await session.ignore(pattern) } }
    if patterns.fileExtension == nil, patterns.folders.isEmpty {
      Button("Add to .gitignore", systemImage: "eye.slash") { _ = ignore(patterns.file) }
    } else {
      let folders = change.path.split(separator: "/").dropLast()
      KitSubmenu("Add to .gitignore", systemImage: "eye.slash") {
        Button(change.fileName, systemImage: "doc") { _ = ignore(patterns.file) }
        if let pattern = patterns.fileExtension {
          let ext = change.fileName.split(separator: ".").last.map(String.init) ?? ""
          Button("All .\(ext) Files", systemImage: "asterisk") { _ = ignore(pattern) }
        }
        ForEach(Array(zip(patterns.folders, folders.indices.reversed())), id: \.0) { pattern, end in
          Button(folders[...end].joined(separator: "/") + "/", systemImage: "folder") { _ = ignore(pattern) }
        }
      }
    }
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

/// A changed file: checkbox, status, name over folder, and line counts. The selected one is raised, as the
/// sidebar's current row.
private struct ChangeRow: View, Equatable {
  let change: FileChange
  let lines: GitKit.LineCounts?
  let isSelected: Bool
  /// Stage or unstage, and select (`ChangeRowActions`).
  let actions: ChangeRowActions

  nonisolated static func == (a: Self, b: Self) -> Bool {
    MainActor.assumeIsolated {
      a.change == b.change && a.lines == b.lines && a.isSelected == b.isSelected && a.actions === b.actions
    }
  }

  private func toggle() { actions.toggle(change) }
  private func select() { actions.select(change) }

  var body: some View {
    let folder = change.originalPath.map { "from \($0)" } ?? (change.directory.isEmpty ? nil : change.directory)
    SidebarRow(change.fileName) {
      HStack(spacing: 8) {
        Toggle(
          (change.area == .staged ? "Unstage " : "Stage ") + change.fileName,
          isOn: .init(get: { change.area == .staged }, set: { _ in toggle() })
        )
        .toggleStyle(.kitCheckbox)
        .kitLabelsHidden()
        .fixedSize()
        ChangeKindBadge(kind: change.kind)
      }
    } trailing: {
      if let lines {
        Diffstat(added: lines.added, removed: lines.removed)
      }
    }
    .subtitle {
      if let folder { Text(folder).truncationMode(.head) }
    }
    .isCurrent(isSelected)
    .action(select)
    .truncationMode(.middle)
    .animation(.kit, value: isSelected)
    .help(change.path)
  }
}

/// What the change list's rows do, in a box the list fills each time it updates: the rows and their menus hold the box
/// rather than closures, so a row whose state didn't change keeps the same inputs (new closures made every row and its
/// menu update on each file picked).
@MainActor private final class ChangeRowActions {
  var toggle: (FileChange) -> Void = { _ in }
  var select: (FileChange) -> Void = { _ in }
  var menu: (FileChange) -> AnyView = { _ in AnyView(EmptyView()) }

  func configured(
    toggle: @escaping (FileChange) -> Void, select: @escaping (FileChange) -> Void,
    menu: @escaping (FileChange) -> AnyView
  ) -> Self {
    self.toggle = toggle
    self.select = select
    self.menu = menu
    return self
  }
}

/// A change row's context menu, built from the box when it opens.
private struct ChangeRowMenu: ViewModifier {
  let change: FileChange
  let actions: ChangeRowActions

  func body(content: Content) -> some View {
    content.kitContextMenu { [actions, change] in actions.menu(change) }
  }
}
