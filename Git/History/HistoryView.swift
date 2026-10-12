import GitKit
import SwiftUI

/// History: a filter bar (All Branches / Current Branch and the commit count), a table of commits
/// with the branch graph, and the selected commit's inspector on the right.
struct HistoryScreen: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        filterBar
        CommitColumnsHeader(graphWidth: graphWidth)
        Divider()
        CommitTable(session: session, state: state, graphWidth: graphWidth)
      }
      .frame(minWidth: 520, maxWidth: .infinity)
      Divider()
      CommitInspector(session: session, state: state)
        .frame(width: 424)
    }
  }

  private var filterBar: some View {
    HStack(spacing: 12) {
      DesignSegmented(
        selection: .init(
          get: { session.logQuery.allBranches },
          set: { all in
            var query = session.logQuery
            query.allBranches = all
            session.logQuery = query
          }),
        options: [("All Branches", true), ("Current Branch", false)])
      Spacer()
      let authors = Set(session.commits.map(\.authorEmail)).count
      Text(
        "\(session.commits.count)\(session.hasMoreCommits ? "+" : "") commit\(session.commits.count == 1 ? "" : "s") · \(authors) author\(authors == 1 ? "" : "s")"
      )
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
      .contentTransition(.numericText(value: Double(session.commits.count)))
      .animation(.app, value: session.commits.count)
    }
    .padding(.horizontal, 16)
    .frame(height: 48)
  }

  /// Room for the widest row's lanes, capped so a busy graph doesn't push the text away.
  private var graphWidth: CGFloat {
    let lanes = min(session.graph.lazy.map(\.width).max() ?? 1, GraphCell.maxLanes)
    return max(56, GraphCell.inset * 2 + CGFloat(max(lanes, 1) - 1) * GraphCell.spacing)
  }
}

/// Column widths shared by the header and the rows.
enum CommitColumns {
  static let author: CGFloat = 132
  static let date: CGFloat = 124
  static let commit: CGFloat = 68
}

private struct CommitColumnsHeader: View {
  let graphWidth: CGFloat

  var body: some View {
    HStack(spacing: 0) {
      Text("Graph").frame(width: graphWidth, alignment: .leading).padding(.leading, 8)
      Text("Description").frame(maxWidth: .infinity, alignment: .leading)
      Text("Author").frame(width: CommitColumns.author, alignment: .leading)
      Text("Date").frame(width: CommitColumns.date, alignment: .leading)
      Text("Commit").frame(width: CommitColumns.commit, alignment: .leading)
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(.secondary)
    .padding(.leading, 4)
    .padding(.trailing, 20)
    .frame(height: 26)
  }
}

/// The commit rows, paged as they scroll, with ↑/↓ to move the selection. ⇧↑/⇧↓ and ⇧-click
/// select several; the context menu squashes several that follow one another.
private struct CommitTable: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  let graphWidth: CGFloat
  @State private var branchStart: Commit?
  @State private var tagTarget: Commit?
  @State private var resetTarget: Commit?
  @State private var squashRequest: SquashRequest?
  /// Where ⇧ ranges start: the commit last selected without ⇧.
  @State private var anchor: Commit.ID?
  @FocusState private var isFocused: Bool

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(Array(session.commits.enumerated()), id: \.element.id) { index, commit in
            CommitRow(
              commit: commit, graph: index < session.graph.count ? session.graph[index] : nil,
              graphWidth: graphWidth, isHead: commit.id == session.status?.headOID,
              isSelected: state.selectedCommit == commit.id
                || state.selectedCommits.contains(commit.id)
            ) {
              click(commit)
            }
            .id(commit.id)
            .contextMenu {
              if state.selectedCommits.count > 1, state.selectedCommits.contains(commit.id) {
                selectionMenu()
              } else {
                contextMenu(for: commit)
              }
            }
            .onAppear {
              if commit.id == session.commits.last?.id {
                Task { await session.loadMoreCommits() }
              }
            }
          }
          if session.isLoadingCommits {
            ProgressView().controlSize(.small).padding(8)
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
      }
      .focusable()
      .focusEffectDisabled()
      .focused($isFocused)
      .onKeyPress(keys: [.upArrow, .downArrow]) { press in
        move(press.key == .downArrow ? 1 : -1, extending: press.modifiers.contains(.shift))
      }
      .onChange(of: state.selectedCommit) { _, id in
        if let id { withAnimation(.app) { proxy.scrollTo(id) } }
      }
    }
    // A commit selected elsewhere (a tag in the sidebar) replaces a selection it isn't part of.
    .onChange(of: state.selectedCommit, initial: true) { _, id in
      guard let id, !state.selectedCommits.contains(id) || state.selectedCommits.count == 1 else {
        return
      }
      state.selectedCommits = [id]
      anchor = id
    }
    .overlay {
      if session.commits.isEmpty && !session.isLoadingCommits {
        if let search = session.logQuery.search {
          ContentUnavailableView.search(text: search)
        } else {
          ContentUnavailableView("No Commits", systemImage: "clock")
        }
      }
    }
    .task(id: session.commits.first?.id) {
      if state.selectedCommit == nil { state.selectedCommit = session.commits.first?.id }
    }
    .sheet(item: $branchStart) { commit in
      NewBranchSheet(session: session, startPoint: commit.id)
    }
    .sheet(item: $tagTarget) { commit in
      NewTagSheet(session: session, commit: commit)
    }
    .sheet(item: $squashRequest) { request in
      SquashSheet(session: session, commits: request.commits) { select($0) }
    }
    .confirmationDialog(
      "Reset \(session.status?.branch ?? "HEAD") to \(resetTarget?.shortID ?? "")?",
      isPresented: .init(get: { resetTarget != nil }, set: { if !$0 { resetTarget = nil } }),
      titleVisibility: .visible
    ) {
      Button("Reset") {
        if let commit = resetTarget { Task { await session.reset(to: commit) } }
      }
    } message: {
      Text(
        "Later commits are removed from the branch. Their changes stay in the working tree, "
          + "so you can commit them again.")
    }
  }

  /// Moves the selection one row; with ⇧ it extends the selection instead.
  private func move(_ offset: Int, extending: Bool) -> KeyPress.Result {
    let commits = session.commits
    guard !commits.isEmpty else { return .ignored }
    let index = state.selectedCommit.flatMap { id in commits.firstIndex { $0.id == id } } ?? -1
    let next = commits[min(max(index + offset, 0), commits.count - 1)].id
    if extending { extendSelection(to: next) } else { select(next) }
    return .handled
  }

  /// Click selects one commit; ⇧-click selects every commit from the anchor to this one.
  private func click(_ commit: Commit) {
    let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
    if flags.contains(.shift) { extendSelection(to: commit.id) } else { select(commit.id) }
    isFocused = true
  }

  private func select(_ id: Commit.ID) {
    anchor = id
    state.selectedCommits = [id]
    state.selectedCommit = id
  }

  /// Selects the commits from the anchor to `id` and shows `id` in the inspector.
  private func extendSelection(to id: Commit.ID) {
    let commits = session.commits
    let start = anchor ?? state.selectedCommit ?? id
    guard let from = commits.firstIndex(where: { $0.id == start }),
      let to = commits.firstIndex(where: { $0.id == id })
    else { return select(id) }
    anchor = start
    state.selectedCommits = Set(commits[min(from, to)...max(from, to)].map(\.id))
    state.selectedCommit = id
  }

  /// The menu for several selected commits: Squash when they follow one another on the current
  /// branch, otherwise the reason it's unavailable.
  @ViewBuilder
  private func selectionMenu() -> some View {
    let selected = state.selectedCommits
    let run = Result { try session.squashRun(selected) }
    Button("Squash \(selected.count) Commits…") {
      if case .success(let commits) = run { squashRequest = SquashRequest(commits: commits) }
    }
    .disabled(session.isBusy || session.status?.operation != nil || (try? run.get()) == nil)
    if case .failure(let error) = run {
      Text((error as? GitError)?.message ?? error.localizedDescription)
    }
    Divider()
    Button("Copy SHAs") {
      copyToPasteboard(
        session.commits.filter { selected.contains($0.id) }.map(\.id).joined(separator: "\n"))
    }
  }

  @ViewBuilder
  private func contextMenu(for commit: Commit) -> some View {
    Button("Check Out") { Task { await session.checkout(commit) } }
      .disabled(session.isBusy)
    Button("Revert Changes in Commit") { Task { await session.revert(commit) } }
      .disabled(session.isBusy)
    Button("Cherry-Pick") { Task { await session.cherryPick(commit) } }
      .disabled(session.isBusy)
    Button("Reset to This Commit…") { resetTarget = commit }
      .disabled(session.isBusy || commit.id == session.status?.headOID)
    Divider()
    Button("Create Branch from Commit…") { branchStart = commit }
    Button("Create Tag…") { tagTarget = commit }
    Divider()
    Button("Copy SHA") { copyToPasteboard(commit.id) }
    Button("Copy Message") { copyToPasteboard(commit.message) }
  }
}

/// Commits to squash, newest first.
private struct SquashRequest: Identifiable {
  let commits: [Commit]
  var id: Commit.ID { commits[0].id }
}

/// The message of the commit that replaces the selected ones, prefilled with theirs (oldest
/// first), and a warning when some of them are already pushed.
private struct SquashSheet: View {
  let session: RepositorySession
  /// Newest first.
  let commits: [Commit]
  let squashed: (Commit.ID) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var summary: String
  @State private var details: String

  init(session: RepositorySession, commits: [Commit], squashed: @escaping (Commit.ID) -> Void) {
    self.session = session
    self.commits = commits
    self.squashed = squashed
    let oldest = commits.last
    let rest = [oldest?.body ?? ""] + commits.dropLast().reversed().map(\.message)
    _summary = State(initialValue: oldest?.subject ?? "")
    _details = State(initialValue: rest.filter { !$0.isEmpty }.joined(separator: "\n\n"))
  }

  var body: some View {
    Form {
      TextField("Summary", text: $summary)
      TextField("Description", text: $details, axis: .vertical)
        .lineLimit(4...12)
      if let oldest = commits.last, let newest = commits.first {
        LabeledContent("Commits", value: "\(oldest.shortID) … \(newest.shortID)")
        LabeledContent("Author", value: oldest.authorName)
      }
      if !commits.allSatisfy(session.isUnpushed) {
        Label(
          "Some of these commits are already pushed. Afterwards, Force Push replaces them on "
            + "the remote.", systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .navigationTitle("Squash \(commits.count) Commits")
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Squash") {
          let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
          let details = details.trimmingCharacters(in: .whitespacesAndNewlines)
          let message = details.isEmpty ? summary : "\(summary)\n\n\(details)"
          let (session, commits, squashed) = (session, commits, squashed)
          Task {
            if let sha = await session.squash(commits, message: message) { squashed(sha) }
          }
          dismiss()
        }
        .disabled(summary.trimmingCharacters(in: .whitespaces).isEmpty || session.isBusy)
      }
    }
  }
}

/// One 44-point commit row: graph, refs and subject, author, date and short sha.
private struct CommitRow: View {
  let commit: Commit
  let graph: GraphRow?
  let graphWidth: CGFloat
  let isHead: Bool
  let isSelected: Bool
  let select: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: select) {
      HStack(spacing: 0) {
        Group {
          if let graph {
            GraphCell(row: graph, isHead: isHead)
          } else {
            Color.clear
          }
        }
        .frame(width: graphWidth, height: 44, alignment: .leading)
        HStack(spacing: 6) {
          ForEach(commit.refs.prefix(3), id: \.self) { ref in
            RefPill(ref: ref)
          }
          Text(commit.subject)
            .fontWeight(isSelected ? .semibold : .regular)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 7) {
          Avatar(name: commit.authorName, size: 20)
          Text(commit.authorName)
            .lineLimit(1)
        }
        .frame(width: CommitColumns.author, alignment: .leading)
        Text(commit.authorDate.historyFormatted)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .frame(width: CommitColumns.date, alignment: .leading)
        Text(commit.shortID)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.secondary)
          .frame(width: CommitColumns.commit, alignment: .leading)
      }
      .padding(.leading, 4)
      .padding(.trailing, 12)
      .frame(height: 44)
      .animation(.app, value: isSelected)
      .animation(.app, value: isHovered)
      .background(
        isSelected
          ? Color.accentColor.opacity(0.14) : Color.primary.opacity(isHovered ? 0.035 : 0),
        in: .rect(cornerRadius: 8, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .help(commit.message)
  }
}

/// A row's slice of the branch graph: lines through the row and the commit's dot. Rows sit
/// edge to edge, so the slices join into continuous lines.
struct GraphCell: View {
  let row: GraphRow
  let isHead: Bool

  static let maxLanes = 8
  static let spacing: CGFloat = 20
  static let inset: CGFloat = 16
  private static let palette: [Color] = [.accentColor, .orange, .purple, .teal, .pink, .green, .indigo, .brown]

  var body: some View {
    Canvas { context, size in
      let mid = size.height / 2
      func x(_ lane: Int) -> CGFloat { Self.inset + CGFloat(min(lane, Self.maxLanes - 1)) * Self.spacing }
      func stroke(_ path: Path, _ color: Int) {
        context.stroke(
          path, with: .color(Self.color(color)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
      }
      /// A line with vertical ends, bending between two lanes.
      func curve(from start: CGPoint, to end: CGPoint) -> Path {
        Path { path in
          path.move(to: start)
          if start.x == end.x {
            path.addLine(to: end)
          } else {
            let middle = (start.y + end.y) / 2
            path.addCurve(
              to: end, control1: CGPoint(x: start.x, y: middle),
              control2: CGPoint(x: end.x, y: middle))
          }
        }
      }
      let node = CGPoint(x: x(row.column), y: mid)
      for edge in row.passing {
        stroke(curve(from: CGPoint(x: x(edge.lane), y: 0), to: CGPoint(x: x(edge.lane), y: size.height)), edge.color)
      }
      for join in row.joining {
        stroke(curve(from: CGPoint(x: x(join.lane), y: 0), to: CGPoint(x: x(join.target), y: size.height)), join.color)
      }
      for edge in row.incoming {
        stroke(curve(from: CGPoint(x: x(edge.lane), y: 0), to: node), edge.color)
      }
      for edge in row.outgoing {
        stroke(curve(from: node, to: CGPoint(x: x(edge.lane), y: size.height)), edge.color)
      }
      let radius: CGFloat = 5
      let dot = Path(ellipseIn: CGRect(x: node.x - radius, y: mid - radius, width: radius * 2, height: radius * 2))
      context.fill(dot, with: .color(isHead ? Self.color(row.color) : Color(nsColor: .textBackgroundColor)))
      context.stroke(dot, with: .color(Self.color(row.color)), lineWidth: 2.5)
    }
    .accessibilityHidden(true)
  }

  private static func color(_ index: Int) -> Color { palette[index % palette.count] }
}
