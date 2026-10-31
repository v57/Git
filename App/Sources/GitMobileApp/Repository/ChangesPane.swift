import ComponentKit
import GitKit
import GitUI
import SwiftUI

/// Changes: the commit composer, then Staged and Unstaged, each file with its checkbox (stage or unstage), status,
/// name over folder and line counts; a tap opens its diff, a long press stages, unstages or discards it.
struct ChangesPane: View {
  let model: RepositoryModel
  @State private var pendingDiscard: [FileChange]?

  var body: some View {
    if let status = model.status {
      ScrollView {
        VStack(alignment: .leading, spacing: KitMetrics.gutter) {
          if status.isClean {
            EmptyState(
              systemImage: "checkmark.circle", title: "No Changes",
              message: "The working tree matches \(status.branch ?? "HEAD").")
              .padding(.top, 40)
          } else {
            CommitComposer(model: model)
            card(
              "Staged", systemImage: "tray", hue: .green, changes: status.staged, action: "Unstage All",
              empty: "Tick a file below to include it in the next commit."
            ) {
              Task { await model.unstageAll() }
            }
            card("Unstaged", systemImage: "pencil", hue: .orange, changes: status.unstaged, action: "Stage All") {
              Task { await model.stageAll() }
            }
          }
          if !status.conflicted.isEmpty {
            Banner(
              "\(status.conflicted.count) Conflicted Files",
              message: "Resolve conflicts in Git on a Mac, then come back to commit.",
              systemImage: "exclamationmark.triangle", hue: .purple)
          }
        }
        .padding(.horizontal, KitMetrics.gutter + 4)
        .padding(.bottom, 24)
        .animation(.kit, value: status)
      }
      .refreshable { await model.refresh() }
      .kitConfirmation(
        discardTitle,
        isPresented: .init(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
        message: discardMessage, systemImage: "trash", confirm: "Discard Changes"
      ) {
        if let changes = pendingDiscard { Task { await model.discard(changes) } }
      }
    } else {
      EmptyState(systemImage: "pencil", title: "Reading Changes", status: .working)
    }
  }

  private func card(
    _ title: String, systemImage: String, hue: Hue, changes: [FileChange], action: String, empty: String? = nil,
    perform: @escaping () -> Void
  ) -> some View {
    KitSection(title, meta: meta(changes), systemImage: systemImage, hue: hue) {
      if changes.isEmpty, let empty {
        Text(empty).kitFont(.caption).foregroundStyle(.kitSecondary).padding(10)
      }
      ForEach(changes) { change in
        row(change).transition(.row)
      }
    } accessory: {
      if !changes.isEmpty {
        HStack(spacing: 2) {
          Button("Discard All…", systemImage: "trash") { pendingDiscard = changes }
            .labelStyle(.iconOnly)
          Button(action, action: perform)
            .buttonStyle(.kitPlain)
        }
        .fixedSize()
        .disabled(model.isBusy)
      }
    }
  }

  private func meta(_ changes: [FileChange]) -> [String] {
    var parts = [changes.count == 1 ? "1 file" : "\(changes.count) files"]
    let counts = changes.compactMap { model.lineCounts[$0.id] }
    if !counts.isEmpty {
      parts.append("+\(counts.compactMap(\.added).reduce(0, +)) −\(counts.compactMap(\.removed).reduce(0, +))")
    }
    return parts
  }

  private func row(_ change: FileChange) -> some View {
    NavigationLink(value: DiffRoute(target: target(change), change: change, kind: change.kind)) {
      ChangeFileRow(change: change, lines: model.lineCounts[change.id]) {
        Task {
          if change.area == .staged { await model.unstage([change]) } else { await model.stage([change]) }
        }
      }
    }
    .buttonStyle(.kitRow)
    .kitContextMenu {
      if change.area == .staged {
        Button("Unstage", systemImage: "minus.circle") { Task { await model.unstage([change]) } }
      } else {
        Button("Stage", systemImage: "plus.circle") { Task { await model.stage([change]) } }
      }
      Button("Discard Changes…", systemImage: "trash", role: .destructive) { pendingDiscard = [change] }
      Divider()
      Button("Copy Path", systemImage: "doc.on.doc") { KitPasteboard.copy(change.path) }
    }
  }

  private func target(_ change: FileChange) -> DiffTarget {
    change.area == .staged
      ? .staged(path: change.path, originalPath: change.originalPath)
      : .unstaged(path: change.path, untracked: change.kind == .untracked)
  }

  private var discardTitle: String {
    guard let changes = pendingDiscard else { return "" }
    return changes.count == 1 ? "Discard changes to \(changes[0].fileName)?" : "Discard changes to \(changes.count) files?"
  }

  private var discardMessage: String {
    guard let changes = pendingDiscard else { return "" }
    let staged = changes.contains { $0.area == .staged }
    let newFiles = model.isRemote ? "New files are moved to the Trash there." : "New files are deleted."
    return (staged ? "Staged and unstaged changes are lost. " : "Unstaged changes are lost. ") + newFiles
  }
}

/// A changed file: checkbox, status, name over folder, line counts and a chevron; 48pt tall.
struct ChangeFileRow: View {
  let change: FileChange
  let lines: GitKit.LineCounts?
  let toggle: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Toggle(
        (change.area == .staged ? "Unstage " : "Stage ") + change.fileName,
        isOn: .init(get: { change.area == .staged }, set: { _ in toggle() })
      )
      .toggleStyle(.kitCheckbox)
      .kitLabelsHidden()
      .fixedSize()
      ChangeKindBadge(kind: change.kind, size: 20)
      VStack(alignment: .leading, spacing: 1) {
        Text(change.fileName)
          .kitFont(.body)
          .lineLimit(1)
          .truncationMode(.middle)
        if let folder = change.originalPath.map({ "from \($0)" }) ?? (change.directory.isEmpty ? nil : change.directory) {
          Text(folder)
            .kitFont(.caption)
            .foregroundStyle(.kitSecondary)
            .lineLimit(1)
            .truncationMode(.head)
        }
      }
      Spacer(minLength: 4)
      if let lines { Diffstat(added: lines.added, removed: lines.removed) }
      Image(systemName: "chevron.right")
        .font(KitFont.callout.font.weight(.semibold))
        .foregroundStyle(.kitTertiary)
    }
    .padding(.horizontal, 10)
    .frame(minHeight: 48)
    .contentShape(Rectangle())
  }
}

/// The commit message and Commit (Commit 3 Files), with Amend where git runs on a Mac. Commit stages everything when
/// nothing is staged yet, as a phone has no room for a second step.
struct CommitComposer: View {
  let model: RepositoryModel
  @State private var message = ""
  @State private var amend = false
  @FocusState private var focused: Bool

  private var staged: Int { model.status?.staged.count ?? 0 }
  private var unstaged: Int { model.status?.unstaged.count ?? 0 }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField(amend ? "Message of the last commit" : "Summary of the changes", text: $message, axis: .vertical)
        .lineLimit(1...6)
        .focused($focused)
        .kitFont(.body)
        .padding(10)
        .background(.kitField, in: RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous))
      HStack(spacing: 8) {
        if model.features.contains(.amend) {
          Toggle("Amend", isOn: $amend)
            .toggleStyle(.kitCheckbox)
            .disabled(model.status?.headOID == nil)
        }
        Spacer(minLength: 0)
        Button {
          Task { await commit() }
        } label: {
          Label(title, systemImage: "checkmark")
        }
        .buttonStyle(.kitPrimary)
        .disabled(!canCommit)
      }
    }
    .padding(KitMetrics.cardPadding)
    .kitSurface(.card)
    .onChange(of: amend) { _, amend in
      guard amend, message.isEmpty else { return }
      Task { message = (try? await model.backend?.lastCommitMessage()) ?? "" }
    }
  }

  private var title: String {
    if amend { return "Amend" }
    let count = staged > 0 ? staged : unstaged
    return count == 1 ? "Commit 1 File" : "Commit \(count) Files"
  }

  private var canCommit: Bool {
    !model.isBusy && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (amend || staged > 0 || unstaged > 0)
  }

  private func commit() async {
    focused = false
    if staged == 0, !amend, unstaged > 0 {
      await model.stageAll()
      guard (model.status?.staged.count ?? 0) > 0 else { return }
    }
    if await model.commit(message: message, amend: amend) {
      message = ""
      amend = false
    }
  }
}
