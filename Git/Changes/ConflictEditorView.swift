import ComponentKit
import GitKit
import SwiftUI

/// Resolve Conflicts: shown in place of Changes while a merge, rebase, cherry-pick or revert
/// waits. A banner counts what is left and has Abort and Continue; the left column lists the
/// conflicted files with a progress bar and the files that merged cleanly; the editor shows each
/// conflict block with the current and incoming sides next to each other.
///
/// Choices are kept in the view state and written only when the operation continues ("Nothing is
/// committed until you continue"). Files without conflict markers (deleted on one side, binary)
/// get a whole-file choice. A file edited by hand until no markers are left counts as resolved.
struct ConflictsScreen: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  @State private var contents: [String: ConflictContent] = [:]
  @State private var isContinuing = false

  private var conflicted: [FileChange] { session.status?.conflicted ?? [] }
  private var operation: RepositoryOperation? { session.status?.operation }

  var body: some View {
    ZStack {
      if let completed = state.completedOperation, operation == nil {
        OperationComplete(session: session, state: state, completed: completed)
          .transition(.page)
      } else {
        VStack(spacing: 0) {
          banner
            .padding(KitMetrics.gutter)
          HStack(alignment: .top, spacing: 0) {
            fileColumn
              .frame(width: 280)
            editor
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .transition(.opacity)
      }
    }
    .animation(.kit, value: state.completedOperation)
    .kitPane(.secondary)
    .background { shortcuts }
    .task(id: LoadKey(revision: session.revision, paths: conflicted.map(\.path))) { await load() }
  }

  private struct LoadKey: Hashable {
    var revision: Int
    var paths: [String]
  }

  // MARK: Loading and progress

  private func load() async {
    guard operation != nil else {
      if state.completedOperation == nil { state.resetConflicts() }
      return
    }
    var loaded: [String: ConflictContent] = [:]
    for change in conflicted {
      loaded[change.path] = await ConflictContent.load(change, in: session.repository)
    }
    guard !Task.isCancelled else { return }
    for change in conflicted {
      if !state.conflictPaths.contains(change.path) { state.conflictPaths.append(change.path) }
      let new = loaded[change.path]
      if new != contents[change.path] {
        // The file changed on disk: earlier choices may not match its blocks any more.
        if contents[change.path] != nil { state.conflictChoices[change.path] = nil }
        if case .blocks(let file) = new { state.conflictBlockCounts[change.path] = file.blocks.count }
      }
    }
    contents = loaded
    if state.selectedConflict.map({ !state.conflictPaths.contains($0) }) ?? true {
      state.selectedConflict =
        conflicted.first(where: { !isResolved($0.path) })?.path ?? state.conflictPaths.first
    }
  }

  /// How many conflicts a path counts for, and how many of them have a choice.
  private func progress(_ path: String) -> (done: Int, total: Int) {
    let total = state.conflictBlockCounts[path] ?? 1
    guard conflicted.contains(where: { $0.path == path }) else { return (total, total) }
    switch contents[path] {
    case .blocks(let file):
      return (min(state.conflictChoices[path]?.count ?? 0, file.blocks.count), file.blocks.count)
    case .text:
      return (total, total)
    case .binary, .missing, nil:
      return (state.wholeFileChoices[path] == nil ? 0 : total, total)
    }
  }

  private func isResolved(_ path: String) -> Bool {
    let progress = progress(path)
    return progress.done == progress.total
  }

  private var totals: (done: Int, total: Int) {
    state.conflictPaths.map(progress).reduce((0, 0)) { ($0.0 + $1.done, $0.1 + $1.total) }
  }

  // MARK: Banner

  private var banner: some View {
    let totals = totals
    let left = totals.total - totals.done
    let isReady = left == 0
    return Banner(
      isReady ? "All conflicts resolved" : left == 1 ? "1 conflict left" : "\(left) conflicts left",
      message: isReady
        ? "Review the result, then continue to finish \(operationNoun)."
        : "Pick a version for each highlighted block. Nothing is committed until you continue.",
      systemImage: isReady ? "checkmark" : "exclamationmark.triangle", hue: isReady ? .green : .orange
    ) {
      Button("Abort \(operationName)") {
        Task {
          await session.abortOperation()
          state.resetConflicts()
        }
      }
      .disabled(session.isBusy)
      Button("Continue \(operationName)") { Task { await continueOperation() } }
        .buttonStyle(.kitPrimary)
        .disabled(!isReady || session.isBusy || isContinuing)
    }
    .animation(.kit, value: left)
  }

  private var operationName: String {
    switch operation {
    case .merge, nil: "Merge"
    case .rebase: "Rebase"
    case .cherryPick: "Cherry-Pick"
    case .revert: "Revert"
    }
  }

  private var operationNoun: String {
    switch operation {
    case .merge, nil: "the merge"
    case .rebase: "the rebase"
    case .cherryPick: "the cherry-pick"
    case .revert: "the revert"
    }
  }

  /// Writes every choice, stages the files and continues the operation.
  private func continueOperation() async {
    guard let operation else { return }
    isContinuing = true
    defer { isContinuing = false }
    for change in conflicted {
      switch contents[change.path] {
      case .blocks(let file):
        guard let text = file.resolved(state.conflictChoices[change.path] ?? [:]),
          await session.resolveConflict(change, with: text)
        else { return }
      case .text:
        await session.stage([change])
      case .binary, .missing, nil:
        guard let side = state.wholeFileChoices[change.path],
          await session.resolveConflict(change, taking: side)
        else { return }
      }
    }
    let completed = CompletedOperation(
      operation: operation, source: session.operationSource, branch: session.status?.branch)
    await session.continueOperation()
    if session.status?.operation == nil {
      state.resetConflicts()
      state.completedOperation = completed
    }
  }

  // MARK: Files

  private var fileColumn: some View {
    let totals = totals
    let mergedCleanly = (session.status?.staged ?? []).filter { !state.conflictPaths.contains($0.path) }
    return ScrollView {
      VStack(alignment: .leading, spacing: KitMetrics.gutter) {
        ConflictFilesCard(
          title: "Conflicts", meta: "\(totals.done) of \(totals.total) resolved",
          systemImage: "exclamationmark.triangle", hue: .orange,
          status: totals.done == totals.total ? .done : .idle
        ) {
          // Files that still need a choice first.
          ForEach(state.conflictPaths.filter { !isResolved($0) } + state.conflictPaths.filter(isResolved), id: \.self) {
            path in
            fileRow(path)
          }
        }
        if !mergedCleanly.isEmpty {
          ConflictFilesCard(
            title: "Merged cleanly", meta: mergedCleanly.count == 1 ? "1 file" : "\(mergedCleanly.count) files",
            systemImage: "checkmark", hue: .green, status: .idle
          ) {
            ForEach(mergedCleanly) { change in
              Text(change.fileName)
                .kitFont(.callout)
                .foregroundStyle(.kitSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .padding(.horizontal, 6)
                .help(change.path)
            }
          }
        }
      }
      .padding([.leading, .bottom], KitMetrics.gutter)
    }
  }

  private func fileRow(_ path: String) -> some View {
    let resolved = isResolved(path)
    let isSelected = state.selectedConflict == path
    return HStack(spacing: 8) {
      Tile(systemImage: resolved ? "checkmark" : "exclamationmark", hue: resolved ? .green : .orange, size: 20, style: .solid)
        .contentTransition(.symbolEffect(.replace))
        .accessibilityLabel(resolved ? "Resolved" : "Has conflicts")
      VStack(alignment: .leading, spacing: 1) {
        Text((path as NSString).lastPathComponent)
          .fontWeight(isSelected ? .medium : .regular)
          .lineLimit(1)
        Text(fileNote(path))
          .kitFont(.caption)
          .lineLimit(1)
          .contentTransition(.interpolate)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 6)
    .frame(height: 44)
    .background {
      if isSelected { Color.clear.kitSurface(.raised, cornerRadius: KitMetrics.radius) }
    }
    .contentShape(Rectangle())
    .onTapGesture { state.selectedConflict = path }
    .animation(.kit, value: resolved)
    .animation(.kit, value: isSelected)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .help(path)
  }

  private func fileNote(_ path: String) -> String {
    guard conflicted.contains(where: { $0.path == path }) else { return "Resolved" }
    switch contents[path] {
    case .blocks(let file):
      let choices = state.conflictChoices[path] ?? [:]
      let open = file.blocks.count - choices.count
      if open > 0 {
        return file.blocks.count == 1
          ? "Needs a choice" : "\(open) of \(file.blocks.count) blocks need a choice"
      }
      let kinds = Set(choices.values)
      if kinds == [.current] { return "Resolved · kept Current" }
      if kinds == [.incoming] { return "Resolved · kept Incoming" }
      return "Resolved"
    case .text:
      return "Resolved by hand"
    case .binary, .missing, nil:
      switch state.wholeFileChoices[path] {
      case .current: return "Resolved · kept Current"
      case .incoming: return "Resolved · kept Incoming"
      case nil: return "Needs a choice"
      }
    }
  }

  // MARK: Editor

  @ViewBuilder
  private var editor: some View {
    if let path = state.selectedConflict {
      let change = conflicted.first { $0.path == path }
      let folder = (path as NSString).deletingLastPathComponent
      ZStack {
      VStack(alignment: .leading, spacing: 0) {
        (Text(folder.isEmpty ? "" : folder + "/").foregroundStyle(.kitSecondary)
          + Text((path as NSString).lastPathComponent).fontWeight(.semibold))
          .kitFont(.mono)
          .textSelection(.enabled)
          .padding(.horizontal, 18)
          .padding(.top, 10)
          .padding(.bottom, 12)
        if let change {
          switch contents[path] {
          case .blocks(let file):
            ScrollView {
              // A few heavy cards: built ahead of the scroll, keeping their heights once measured.
              KitLazyStack(alignment: .leading, spacing: 8) {
                ForEach(Array(file.segments.enumerated()), id: \.offset) { index, segment in
                  switch segment {
                  case .common(let text):
                    CommonText(
                      text: text, showsStart: index > 0, showsEnd: index < file.segments.count - 1)
                  case .conflict(let block):
                    ConflictBlockCard(
                      block: block, count: file.blocks.count, context: ConflictContext.describe(block, in: file),
                      currentName: currentName(block),
                      order: session.status?.operation == .rebase ? .incomingFirst : .currentFirst,
                      resolution: .init(
                        get: { state.conflictChoices[path]?[block.id] },
                        set: { state.conflictChoices[path, default: [:]][block.id] = $0 })
                    ) {
                      openFile(path)
                    }
                  }
                }
              }
              .padding(.horizontal, KitMetrics.gutter)
              .padding(.bottom, 32)
            }
          case .some(let content):
            WholeFileCard(
              change: change, content: content, currentName: session.status?.branch ?? "Current",
              incomingName: session.operationSource ?? "Incoming",
              choice: state.wholeFileChoices[path]
            ) { side in
              state.wholeFileChoices[path] = side
            } editManually: {
              openFile(path)
            }
            .padding(.horizontal, KitMetrics.gutter)
            Spacer()
          case nil:
            LiveIcon(systemImage: "doc.text", hue: .gray, status: .working)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        } else {
          EmptyState(systemImage: "checkmark", title: "Resolved", message: "This file is resolved and staged.")
        }
      }
      .id(path)
      .transition(.page)
      }
      .animation(.kit, value: path)
    } else {
      EmptyState(systemImage: "checkmark", title: "No Conflicts")
    }
  }

  /// "main" instead of the `HEAD` marker label.
  private func currentName(_ block: ConflictBlock) -> String {
    block.currentLabel == "HEAD" || block.currentLabel.isEmpty
      ? (session.status?.branch ?? "HEAD") : block.currentLabel
  }

  private func openFile(_ path: String) {
    NSWorkspace.shared.open(session.repository.url.appendingPathComponent(path))
  }

  /// ⌥⌘← and ⌥⌘→ choose a side for the next open conflict in the selected file.
  private var shortcuts: some View {
    Group {
      Button("Use Current for Next Conflict") { chooseNext(.current) }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
      Button("Use Incoming for Next Conflict") { chooseNext(.incoming) }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  private func chooseNext(_ resolution: ConflictResolution) {
    guard let path = state.selectedConflict else { return }
    switch contents[path] {
    case .blocks(let file):
      if let block = file.blocks.first(where: { state.conflictChoices[path]?[$0.id] == nil }) {
        state.conflictChoices[path, default: [:]][block.id] = resolution
      }
    case .binary, .missing:
      state.wholeFileChoices[path] = resolution == .current ? .current : .incoming
    default:
      break
    }
  }
}

/// What a conflicted file holds on disk.
enum ConflictContent: Equatable {
  case blocks(ConflictedFile)
  /// Text without conflict markers: resolved by hand, or never had any.
  case text
  case binary
  /// Deleted on one side (a keep-or-delete choice), or gone from the working tree.
  case missing

  static func load(_ change: FileChange, in repository: Repository) async -> ConflictContent {
    if change.conflict?.involvesDeletion == true { return .missing }
    guard let data = await repository.contents(of: change.path, at: .workingTree) else {
      return .missing
    }
    guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return .binary }
    return ConflictParser.parse(text).map(ConflictContent.blocks) ?? .text
  }
}

/// A card of conflicted (or cleanly merged) files under a rich header.
private struct ConflictFilesCard<Rows: View>: View {
  let title: String
  let meta: String
  let systemImage: String
  let hue: Hue
  let status: WorkStatus
  @ViewBuilder let rows: () -> Rows

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      RichHeader(title, meta: meta, systemImage: systemImage, hue: hue, status: status)
      rows()
    }
    .padding(KitMetrics.cardPadding)
    .kitSurface(.card)
  }
}

/// Text both sides agree on. Long runs are cut to a few lines of context around the conflicts.
private struct CommonText: View {
  let text: String
  let showsStart: Bool
  let showsEnd: Bool

  private static let context = 3

  var body: some View {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .newlines) }
    let body = lines.last == "" ? Array(lines.dropLast()) : lines
    VStack(alignment: .leading, spacing: 4) {
      if body.count <= Self.context * 2 + 1 {
        code(body)
      } else {
        if showsStart { code(Array(body.prefix(Self.context))) }
        let hidden = body.count - (showsStart ? Self.context : 0) - (showsEnd ? Self.context : 0)
        Label("\(hidden) unchanged lines", systemImage: "ellipsis")
          .kitFont(.caption)
        if showsEnd { code(Array(body.suffix(Self.context))) }
      }
    }
    .padding(.vertical, 4)
  }

  private func code(_ lines: [String]) -> some View {
    Text(verbatim: lines.joined(separator: "\n"))
      .kitFont(.mono)
      .foregroundStyle(.kitSecondary)
      .lineSpacing(4)
      .textSelection(.enabled)
      .padding(.horizontal, 10)
  }
}

/// One conflict block as the kit's conflict card: Current, Incoming or Both, then the result, with
/// the common ancestor on demand (diff3 and zdiff3 conflict styles). A rebase shows Incoming first,
/// and Both keeps it first.
private struct ConflictBlockCard: View {
  let block: ConflictBlock
  let count: Int
  /// Where the block sits, e.g. "refresh()" or "stored properties".
  let context: String?
  let currentName: String
  let order: ConflictOrder
  @Binding var resolution: ConflictResolution?
  let editManually: () -> Void

  private var lineRange: String {
    let count = max(ConflictParser.lines(of: block.current).count, ConflictParser.lines(of: block.incoming).count, 1)
    return count == 1 ? "Line \(block.line)" : "Lines \(block.line)–\(block.line + count - 1)"
  }

  private var choice: Binding<ConflictChoice?> {
    Binding(
      get: {
        switch resolution {
        case .current: .current
        case .incoming: .incoming
        case .currentThenIncoming, .incomingThenCurrent: .both
        case nil: nil
        }
      },
      set: { choice in
        switch choice {
        case .current: resolution = .current
        case .incoming: resolution = .incoming
        case .both: resolution = order == .incomingFirst ? .incomingThenCurrent : .currentThenIncoming
        case nil: resolution = nil
        }
      })
  }

  var body: some View {
    ConflictCard(
      title: "Conflict \(block.id + 1) of \(count)",
      meta: [lineRange, context ?? ""],
      current: ComponentKit.ConflictSide("Current", ref: currentName, code: Self.code(block.current)),
      incoming: ComponentKit.ConflictSide("Incoming", ref: block.incomingLabel, code: Self.code(block.incoming)),
      ancestor: block.base.map { ComponentKit.ConflictSide("Base", code: Self.code($0)) },
      order: order, choice: choice, edit: editManually
    )
  }

  /// A side's text without its final newline.
  private static func code(_ text: String) -> String {
    text.hasSuffix("\n") ? String(text.dropLast()) : text
  }
}

/// A conflict without blocks: keep or delete a file one side deleted, take one side of a binary
/// file, or accept a file edited by hand.
private struct WholeFileCard: View {
  let change: FileChange
  let content: ConflictContent
  let currentName: String
  let incomingName: String
  let choice: GitKit.ConflictSide?
  let choose: (GitKit.ConflictSide?) -> Void
  let editManually: () -> Void

  var body: some View {
    let isResolved = choice != nil || content == .text
    VStack(alignment: .leading, spacing: 8) {
      RichHeader(
        change.conflict?.title ?? "Conflict", meta: choice.map(choiceDescription) ?? message,
        systemImage: "exclamationmark.triangle", hue: .orange, status: isResolved ? .done : .idle)
      HStack(spacing: 8) {
          Spacer()
          if choice != nil {
            Button("Change") { choose(nil) }
          } else if content == .text {
            Button("Edit Manually…", action: editManually)
          } else {
            Group {
            switch change.conflict {
            case .deletedByThem:
              Button("Delete File") { choose(.incoming) }
              Button("Keep File") { choose(.current) }
            case .deletedByUs:
              Button("Delete File") { choose(.current) }
              Button("Keep File") { choose(.incoming) }
            case .bothDeleted:
              Button("Delete File") { choose(.current) }
            default:
              Button("Use Current") { choose(.current) }
              Button("Use Incoming") { choose(.incoming) }
            }
            if content == .binary {
              Button("Edit Manually…", action: editManually)
            }
            }
          }
      }
      .buttonStyle(.kit)
      .controlSize(.small)
    }
    .padding(KitMetrics.cardPadding)
    .kitSurface(.card)
    .animation(.kit, value: isResolved)
  }

  private var message: String {
    switch change.conflict {
    case .deletedByThem: return "\(currentName) changed this file and \(incomingName) deleted it."
    case .deletedByUs: return "\(currentName) deleted this file and \(incomingName) changed it."
    case .bothDeleted: return "Both sides deleted this file."
    default:
      switch content {
      case .binary: return "This file is binary. Keep one side's version."
      case .text: return "No conflict markers are left. It is staged when you continue."
      default: return "The file is missing from the working tree."
      }
    }
  }

  private func choiceDescription(_ side: GitKit.ConflictSide) -> String {
    switch (change.conflict, side) {
    case (.deletedByThem, .incoming), (.deletedByUs, .current), (.bothDeleted, _): "The file is deleted."
    case (.deletedByThem, .current), (.deletedByUs, .incoming): "The file is kept."
    case (_, .current): "Kept Current (\(currentName))."
    case (_, .incoming): "Kept Incoming (\(incomingName))."
    }
  }
}

/// After Continue: what finished, with View History and Push.
private struct OperationComplete: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  let completed: CompletedOperation
  private var title: String {
    switch completed.operation {
    case .merge: "Merge complete"
    case .rebase: "Rebase complete"
    case .cherryPick: "Cherry-pick complete"
    case .revert: "Revert complete"
    }
  }

  private var message: String {
    let branch = completed.branch ?? "the current branch"
    switch completed.operation {
    case .merge:
      return "\(completed.source ?? "The branch") is now part of \(branch). Push when you are ready to share it."
    case .rebase: return "\(completed.source ?? "The branch") now sits on top of its new base."
    case .cherryPick: return "The commit was applied to \(branch). Push when you are ready to share it."
    case .revert: return "The revert was committed to \(branch). Push when you are ready to share it."
    }
  }

  private var remote: String {
    session.status?.upstream.map { String($0.prefix { $0 != "/" }) }
      ?? (session.remotes.contains("origin") ? "origin" : session.remotes.first ?? "origin")
  }

  var body: some View {
    EmptyState(systemImage: "checkmark", title: title, message: message) {
      Button("View History") { state.mode = .history }
        .buttonStyle(.kit)
      if !session.remotes.isEmpty {
        Button("Push to \(remote)") { Task { await session.push() } }
          .buttonStyle(.kitPrimary)
          .disabled(session.isBusy)
      }
    }
  }
}

/// Where a conflict block sits in its file: the function it is in ("refresh()"), or "stored
/// properties" for declarations directly inside a type.
enum ConflictContext {
  static func describe(_ block: ConflictBlock, in file: ConflictedFile) -> String? {
    // The text before the block, newest line first.
    var before: [String] = []
    for segment in file.segments {
      switch segment {
      case .common(let text): before += ConflictParser.lines(of: text).map(String.init)
      case .conflict(let other):
        if other.id == block.id { return scan(before.reversed(), block: block) }
        before += ConflictParser.lines(of: other.current).map(String.init)
      }
    }
    return nil
  }

  private static func scan(_ lines: some Sequence<String>, block: ConflictBlock) -> String? {
    var depth = 0
    for line in lines {
      depth += line.filter { $0 == "}" }.count - line.filter { $0 == "{" }.count
      guard depth < 0 else { continue }
      // The innermost open scope.
      let words = line.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
      if let index = words.firstIndex(of: "func"), index + 1 < words.count {
        return "\(words[index + 1])()"
      }
      if words.contains(where: { ["class", "struct", "enum", "actor", "extension"].contains($0) }) {
        let declares = (block.current + block.incoming).split(separator: "\n").allSatisfy {
          let trimmed = $0.trimmingCharacters(in: .whitespaces)
          return trimmed.isEmpty || trimmed.hasPrefix("@") || trimmed.contains("var ") || trimmed.contains("let ")
        }
        return declares ? "stored properties" : nil
      }
      return nil
    }
    return nil
  }
}
