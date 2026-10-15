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
          Divider()
          HStack(spacing: 0) {
            fileColumn
              .frame(width: 280)
            Divider()
            editor
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .transition(.opacity)
      }
    }
    .animation(.kit, value: state.completedOperation)
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
    return HStack(spacing: 12) {
      Image(systemName: isReady ? "checkmark" : "exclamationmark")
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(.white)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: 28, height: 28)
        .background(isReady ? Color.green : Color.orange, in: .circle)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(isReady ? "All conflicts resolved" : left == 1 ? "1 conflict left" : "\(left) conflicts left")
          .fontWeight(.semibold)
          .contentTransition(.numericText(value: Double(left)))
        Text(
          isReady
            ? "Review the result, then continue to finish \(operationNoun)."
            : "Pick a version for each highlighted block. Nothing is committed until you continue."
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button("Abort \(operationName)") {
        Task {
          await session.abortOperation()
          state.resetConflicts()
        }
      }
      .buttonStyle(.design)
      .disabled(session.isBusy)
      Button("Continue \(operationName)") { Task { await continueOperation() } }
        .buttonStyle(.design(.primary, padding: 14))
        .disabled(!isReady || session.isBusy || isContinuing)
    }
    .padding(.leading, 20)
    .padding(.trailing, 16)
    .padding(.vertical, 12)
    .background((isReady ? Color.green : Color.orange).opacity(0.1))
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
      VStack(alignment: .leading, spacing: 4) {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline) {
            Text("Conflicts").fontWeight(.semibold)
            Spacer()
            Text("\(totals.done) of \(totals.total) resolved")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .contentTransition(.numericText(value: Double(totals.done)))
              .animation(.kit, value: totals.done)
          }
          ProgressBar(
            value: totals.total == 0 ? 1 : Double(totals.done) / Double(totals.total),
            color: totals.done == totals.total ? .green : .orange)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        // Files that still need a choice first.
        ForEach(state.conflictPaths.filter { !isResolved($0) } + state.conflictPaths.filter(isResolved), id: \.self) { path in
          fileRow(path)
        }
        if !mergedCleanly.isEmpty {
          SectionTitle("Merged cleanly · \(mergedCleanly.count)")
            .padding(.horizontal, 8)
            .padding(.top, 18)
            .padding(.bottom, 6)
          ForEach(mergedCleanly) { change in
            Text(change.fileName)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .frame(height: 26)
              .padding(.horizontal, 10)
              .help(change.path)
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 14)
    }
    .background(Color.primary.opacity(0.015))
  }

  private func fileRow(_ path: String) -> some View {
    let resolved = isResolved(path)
    let isSelected = state.selectedConflict == path
    return Button {
      state.selectedConflict = path
    } label: {
      HStack(spacing: 10) {
        Image(systemName: resolved ? "checkmark" : "exclamationmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(.white)
          .contentTransition(.symbolEffect(.replace))
          .frame(width: 20, height: 20)
          .background(resolved ? Color.green : Color.orange, in: .circle)
          .accessibilityLabel(resolved ? "Resolved" : "Has conflicts")
        VStack(alignment: .leading, spacing: 1) {
          Text((path as NSString).lastPathComponent)
            .fontWeight(isSelected ? .semibold : .medium)
            .lineLimit(1)
          Text(fileNote(path))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .contentTransition(.interpolate)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .frame(height: 44)
      .background(
        isSelected ? Color.accentColor.opacity(0.14) : .clear,
        in: .rect(cornerRadius: 8, style: .continuous)
      )
      .animation(.kit, value: resolved)
      .animation(.kit, value: isSelected)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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
        (Text(folder.isEmpty ? "" : folder + "/").foregroundStyle(.secondary)
          + Text((path as NSString).lastPathComponent).fontWeight(.semibold))
          .font(.system(size: 12.5, design: .monospaced))
          .textSelection(.enabled)
          .padding(.horizontal, 24)
          .padding(.top, 18)
          .padding(.bottom, 12)
        if let change {
          switch contents[path] {
          case .blocks(let file):
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(file.segments.enumerated()), id: \.offset) { index, segment in
                  switch segment {
                  case .common(let text):
                    CommonText(
                      text: text, showsStart: index > 0, showsEnd: index < file.segments.count - 1)
                  case .conflict(let block):
                    ConflictBlockCard(
                      block: block, context: ConflictContext.describe(block, in: file),
                      currentName: currentName(block),
                      resolution: state.conflictChoices[path]?[block.id]
                    ) { resolution in
                      state.conflictChoices[path, default: [:]][block.id] = resolution
                    } editManually: {
                      openFile(path)
                    }
                  }
                }
              }
              .padding(.horizontal, 24)
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
            .padding(.horizontal, 24)
            Spacer()
          case nil:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        } else {
          ContentUnavailableView(
            "Resolved", systemImage: "checkmark.circle",
            description: Text("This file is resolved and staged."))
        }
      }
      .id(path)
      .transition(.page)
      }
      .animation(.kit, value: path)
    } else {
      ContentUnavailableView("No Conflicts", systemImage: "checkmark.circle")
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

private struct ProgressBar: View {
  let value: Double
  let color: Color

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.1))
        Capsule().fill(color).frame(width: proxy.size.width * min(max(value, 0), 1))
      }
    }
    .frame(height: 6)
    .animation(.kit, value: value)
    .accessibilityElement()
    .accessibilityLabel("Conflicts resolved")
    .accessibilityValue("\(Int(value * 100)) percent")
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
          .font(.caption)
          .foregroundStyle(.tertiary)
        if showsEnd { code(Array(body.suffix(Self.context))) }
      }
    }
    .padding(.vertical, 4)
  }

  private func code(_ lines: [String]) -> some View {
    Text(verbatim: lines.joined(separator: "\n"))
      .font(.system(size: 12, design: .monospaced))
      .foregroundStyle(.secondary)
      .lineSpacing(4)
      .textSelection(.enabled)
      .padding(.horizontal, 2)
  }
}

/// The card around a conflict: a header with the status chip, then the body.
private struct ConflictCard<Content: View>: View {
  let title: String
  let detail: String
  let isResolved: Bool
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text(title).fontWeight(.semibold)
        Text(detail)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        Spacer()
        Text(isResolved ? "Resolved" : "Needs a choice")
          .font(.system(size: 11, weight: .semibold))
          .contentTransition(.interpolate)
          .foregroundStyle(isResolved ? Color.green : Color.orange)
          .padding(.horizontal, 8)
          .frame(height: 20)
          .background((isResolved ? Color.green : Color.orange).opacity(0.15), in: .capsule)
      }
      .padding(.horizontal, 14)
      .frame(height: 38)
      .background(Color.primary.opacity(0.03))
      Divider()
      content()
    }
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(.rect(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder((isResolved ? Color.green : Color.orange).opacity(0.45))
    }
    .animation(.kit, value: isResolved)
    .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
  }
}

/// One conflict block: the current and incoming sides next to each other, or the chosen result.
private struct ConflictBlockCard: View {
  let block: ConflictBlock
  /// Where the block sits, e.g. "refresh()" or "stored properties".
  let context: String?
  let currentName: String
  let resolution: ConflictResolution?
  let choose: (ConflictResolution?) -> Void
  let editManually: () -> Void
  @State private var showsBase = false

  private var lineRange: String {
    let count = max(lineCount(block.current), lineCount(block.incoming), 1)
    return count == 1 ? "Line \(block.line)" : "Lines \(block.line)–\(block.line + count - 1)"
  }

  private func lineCount(_ text: String) -> Int {
    ConflictParser.lines(of: text).count
  }

  var body: some View {
    ConflictCard(
      title: "Conflict \(block.id + 1)", detail: [lineRange, context].compactMap { $0 }.joined(separator: " · "),
      isResolved: resolution != nil
    ) {
      ZStack {
        if let resolution {
          resolved(resolution)
            .transition(.opacity)
        } else {
          sides
            .transition(.opacity)
        }
      }
      .animation(.kit, value: resolution)
    }
  }

  private var hint: String {
    if block.current.isEmpty { return "The current side removed these lines; the incoming side changed them." }
    if block.incoming.isEmpty { return "The incoming side removed these lines; the current side changed them." }
    if let base = block.base, base == block.current { return "Only the incoming side changed these lines." }
    if let base = block.base, base == block.incoming { return "Only the current side changed these lines." }
    return "Both sides changed these lines. Use Both keeps them one after the other."
  }

  private var sides: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 0) {
        side(
          title: "Current", label: currentName, text: block.current, tint: .accentColor,
          action: "Use Current"
        ) { choose(.current) }
        Divider()
        side(
          title: "Incoming", label: block.incomingLabel, text: block.incoming, tint: .orange,
          action: "Use Incoming"
        ) { choose(.incoming) }
      }
      .fixedSize(horizontal: false, vertical: true)
      if let base = block.base, showsBase {
        Divider()
        VStack(alignment: .leading, spacing: 4) {
          SectionTitle("Common ancestor")
          CodeText(text: base)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.03))
      }
      Divider()
      HStack(spacing: 8) {
        Text(hint)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(2)
        if block.base != nil {
          Button(showsBase ? "Hide Ancestor" : "Show Ancestor") { showsBase.toggle() }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
        Spacer(minLength: 8)
        Button("Use Both") { choose(.currentThenIncoming) }
          .buttonStyle(.design(size: .small))
          .help("Keep both, Current first. Right-click to put Incoming first.")
          .contextMenu {
            Button("Current, Then Incoming") { choose(.currentThenIncoming) }
            Button("Incoming, Then Current") { choose(.incomingThenCurrent) }
          }
        Button("Edit Manually…", action: editManually)
          .buttonStyle(.design(size: .small))
      }
      .padding(.leading, 14)
      .padding(.trailing, 10)
      .padding(.vertical, 10)
    }
  }

  private func side(
    title: String, label: String, text: String, tint: Color, action: String,
    choose: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Circle().fill(tint).frame(width: 8, height: 8)
        Text(title).fontWeight(.semibold)
        Text(label)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 4)
        Button(action, action: choose)
          .buttonStyle(.design(size: .small))
      }
      .padding(.leading, 14)
      .padding(.trailing, 8)
      .frame(height: 40)
      CodeText(text: text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(tint.opacity(0.08))
        .overlay(alignment: .top) { Rectangle().fill(tint.opacity(0.18)).frame(height: 1) }
    }
    .frame(maxWidth: .infinity)
  }

  private func resolved(_ resolution: ConflictResolution) -> some View {
    let lines = resultLines(resolution)
    return VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          HStack(spacing: 0) {
            Rectangle().fill(line.tint).frame(width: 6)
            Text(verbatim: line.text)
              .font(.system(size: 12, design: .monospaced))
              .lineLimit(1)
              .padding(.leading, 8)
              .padding(.trailing, 14)
            Spacer(minLength: 0)
          }
          .frame(height: 22)
        }
        if lines.isEmpty {
          Text("No lines")
            .font(.callout.italic())
            .foregroundStyle(.secondary)
            .padding(14)
        }
      }
      .padding(.vertical, 8)
      .background(Color.green.opacity(0.06))
      Divider()
      HStack {
        Text(description(resolution))
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        Spacer()
        Button("Change") { choose(nil) }
          .buttonStyle(.borderless)
          .fontWeight(.medium)
      }
      .padding(.leading, 14)
      .padding(.trailing, 10)
      .padding(.vertical, 8)
    }
  }

  private func resultLines(_ resolution: ConflictResolution) -> [(text: String, tint: Color)] {
    func lines(_ text: String, _ tint: Color) -> [(text: String, tint: Color)] {
      ConflictParser.lines(of: text).map { (String($0).trimmingCharacters(in: .newlines), tint) }
    }
    let current = lines(block.current, .accentColor)
    let incoming = lines(block.incoming, .orange)
    switch resolution {
    case .current: return current
    case .incoming: return incoming
    case .currentThenIncoming: return current + incoming
    case .incomingThenCurrent: return incoming + current
    }
  }

  private func description(_ resolution: ConflictResolution) -> String {
    switch resolution {
    case .current: "Kept Current (\(currentName))."
    case .incoming: "Kept Incoming (\(block.incomingLabel))."
    case .currentThenIncoming: "Kept both, Current first."
    case .incomingThenCurrent: "Kept both, Incoming first."
    }
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
    ConflictCard(
      title: change.conflict?.title ?? "Conflict", detail: "",
      isResolved: choice != nil || content == .text
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Text(message)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          if let choice {
            Text(choiceDescription(choice))
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
            Spacer()
            Button("Change") { choose(nil) }
              .buttonStyle(.design(size: .small))
          } else if content == .text {
            Spacer()
            Button("Edit Manually…", action: editManually)
              .buttonStyle(.design(size: .small))
          } else {
            Spacer()
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
            .buttonStyle(.design(size: .small))
          }
        }
      }
      .padding(14)
    }
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

/// Monospaced lines; an empty side says so.
private struct CodeText: View {
  let text: String

  var body: some View {
    if text.isEmpty {
      Text("No lines")
        .font(.callout.italic())
        .foregroundStyle(.secondary)
    } else {
      // One line per row, cut at the edge rather than wrapped, so the code keeps its shape.
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(ConflictParser.lines(of: text).enumerated()), id: \.offset) { _, line in
          Text(verbatim: String(line).trimmingCharacters(in: .newlines))
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: 20, alignment: .leading)
        }
      }
      .textSelection(.enabled)
    }
  }
}

/// After Continue: what finished, with View History and Push.
private struct OperationComplete: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  let completed: CompletedOperation
  @State private var appeared = false

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
    VStack(spacing: 10) {
      Image(systemName: "checkmark")
        .font(.system(size: 30, weight: .semibold))
        .foregroundStyle(.green)
        .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
        .onAppear { appeared = true }
        .frame(width: 64, height: 64)
        .background(Color.green.opacity(0.15), in: .circle)
        .accessibilityHidden(true)
      Text(title)
        .font(.system(size: 20, weight: .semibold))
        .padding(.top, 6)
      Text(message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)
      HStack(spacing: 8) {
        Button("View History") { state.mode = .history }
          .buttonStyle(.design(size: .large))
        if !session.remotes.isEmpty {
          Button("Push to \(remote)") { Task { await session.push() } }
            .buttonStyle(.design(.primary, size: .large))
            .disabled(session.isBusy)
        }
      }
      .padding(.top, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
