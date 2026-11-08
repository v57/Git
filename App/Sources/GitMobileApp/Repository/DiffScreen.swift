import ComponentKit
import GitKit
import GitUI
import SwiftUI

/// One file's diff as the kit's hunk cards (the Mac's), syntax colored. For a change in Changes: Stage or Unstage and
/// Discard in the bar, and where git runs on a Mac, single lines and hunks stage, unstage and discard in the cards.
/// It reloads after every refresh. When the file has no changes left where it was (staged, unstaged, its last hunk
/// moved), it follows the file to the other side, or goes back once the file has no changes at all.
struct DiffScreen: View {
  let model: RepositoryModel
  let opened: DiffRoute
  /// Where the file went after staging or unstaging it (`follow`), else nil: the route it was opened with.
  @State private var followed: DiffRoute?
  @State private var content: LoadedDiff?
  @State private var isLoaded = false
  @State private var error: String?
  @State private var selection: Set<Int> = []
  @State private var pendingDiscard = false
  /// The hunk's lines Discard Hunk… asked to discard, until the confirmation answers (G-007).
  @State private var pendingDiscardLines: Set<Int>?
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dismiss) private var dismiss

  private var route: DiffRoute { followed ?? opened }
  private var path: String { route.target.path }
  private var name: String { (path as NSString).lastPathComponent }

  var body: some View {
    Group {
      if let content {
        if content.diff.isBinary {
          EmptyState(systemImage: "doc", title: "Binary File", message: "\(name) changed; its contents aren’t text.")
        } else if content.diff.hunks.isEmpty {
          EmptyState(systemImage: "doc", title: "No Line Changes", message: "Only the file’s mode changed.")
        } else {
          ScrollView {
            HunkCards(content: content, mode: mode, selection: $selection)
              .padding(.horizontal, KitMetrics.gutter)
              .padding(.vertical, 8)
          }
        }
      } else if let error {
        EmptyState(systemImage: "doc", title: "Couldn’t Show \(name)", message: error, status: .failed(nil))
      } else if isLoaded {
        EmptyState(systemImage: "checkmark.circle", title: "No Changes", message: "\(name) has no changes here anymore.")
      } else {
        EmptyState(systemImage: "doc.text", title: "Reading \(name)", status: .working)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.kitWindow)
    .kitPane(.content)
    .kitToolbar(name, title: {
      RichHeader(Text(name), size: .title) {
        ChangeKindBadge(kind: route.kind, size: 28)
      } meta: {
        MetaLine(meta)
      } accessory: {
        EmptyView()
      }
    }) {
      if let change = route.change {
        ToolGroup(iconOnly: true) {
          Button("Discard Changes…", systemImage: "trash") { pendingDiscard = true }
          if change.area == .staged {
            Button("Unstage", systemImage: "minus.circle") { Task { await model.unstage([change]) } }
          } else {
            Button("Stage", systemImage: "plus.circle") { Task { await model.stage([change]) } }
          }
        }
        .disabled(model.isBusy)
      }
    }
    .navigationBarBackButtonHidden(true)
    .kitConfirmation(
      "Discard changes to \(name)?", isPresented: $pendingDiscard,
      message: route.change?.kind == .untracked ? "The new file is thrown away." : "Its changes are lost.",
      systemImage: "trash", confirm: "Discard Changes"
    ) {
      if let change = route.change {
        Task {
          await model.discard([change])
          dismiss()
        }
      }
    }
    .kitConfirmation(
      "Discard this hunk?",
      isPresented: .init(get: { pendingDiscardLines != nil }, set: { if !$0 { pendingDiscardLines = nil } }),
      message: "The working-tree changes on these lines in \(name) are lost.", systemImage: "trash",
      confirm: "Discard Hunk"
    ) {
      if let lines = pendingDiscardLines, let diff = content?.diff {
        Task { await model.discardLines(lines, of: diff) }
        selection = []
      }
    }
    .task(id: LoadKey(route: route, revision: model.revision, dark: colorScheme == .dark)) { await load() }
  }

  private var meta: [String] {
    var parts: [String] = []
    let folder = (path as NSString).deletingLastPathComponent
    if !folder.isEmpty { parts.append(folder) }
    switch route.target {
    case .unstaged: parts.append("Unstaged")
    case .staged: parts.append("Staged")
    case .commit(let sha, _, _, _): parts.append(String(sha.prefix(7)))
    }
    if let diff = content?.diff, !diff.isBinary { parts.append("+\(diff.additions) −\(diff.deletions)") }
    return parts
  }

  /// Line staging where the backend has it and the diff allows it (not for a commit's file).
  private var mode: HunkCards.Mode {
    guard model.features.contains(.lineStaging), let diff = content?.diff, diff.supportsLineSelection,
      let change = route.change
    else { return .readOnly }
    if change.area == .staged {
      return .staged { lines in Task { await model.unstageLines(lines, of: diff) } }
    }
    return .unstaged(
      stage: { lines in Task { await model.stageLines(lines, of: diff) } },
      discard: { lines in pendingDiscardLines = lines })
  }

  private struct LoadKey: Hashable {
    var route: DiffRoute
    var revision: Int
    var dark: Bool
  }

  private func load() async {
    guard let backend = model.backend else { return }
    let target = route.target
    do {
      let loaded = try await LoadedDiff.load(
        target, isDark: colorScheme == .dark, diff: { try await backend.diff(target) },
        contents: { await backend.contents(of: $0, at: $1) })
      content = loaded
      error = nil
      if loaded == nil, follow() { return }
      selection = selection.filter { id in loaded?.diff.lines.contains { $0.id == id } ?? false }
    } catch {
      self.error = RepositoryModel.describe(error)
    }
    isLoaded = true
  }

  /// A change with nothing left on its side: the screen shows the file on the other side (Stage in the bar showed
  /// "No Changes" with Stage still there, G-001), or goes back when it has no changes at all. True when it moved on.
  private func follow() -> Bool {
    guard let change = route.change, let status = model.status else { return false }
    let other = change.area == .staged ? status.unstaged : status.staged
    if let moved = other.first(where: { $0.path == change.path }) {
      followed = DiffRoute(moved)
      return true
    }
    let same = change.area == .staged ? status.staged : status.unstaged
    guard !same.contains(where: { $0.path == change.path }) else { return false }
    dismiss()
    return true
  }
}

extension DiffRoute {
  /// A file in Changes: its staged or unstaged diff.
  init(_ change: FileChange) {
    let target: DiffTarget =
      change.area == .staged
      ? .staged(path: change.path, originalPath: change.originalPath)
      : .unstaged(path: change.path, untracked: change.kind == .untracked)
    self.init(target: target, change: change, kind: change.kind)
  }
}
