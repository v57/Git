import ComponentKit
import GitKit
import GitRemote
import GitUI
import SwiftUI

/// History: what isn't in sync first, each in its own card with its action (To pull, To push),
/// then the branch's history card. The author's avatar is each commit's node on the branch graph,
/// whose lanes run on through the gaps between the cards. The selected commit's inspector is on
/// the right.
struct HistoryScreen: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  /// Commits on the upstream that HEAD doesn't have, and HEAD's commits the upstream doesn't.
  @State private var sync = SyncCommits()

  var body: some View {
    ResizableSplit(
      "HistoryInspectorWidth", pane: .trailing, width: 424, range: 340...720, mainMinWidth: 520
    ) {
      CommitList(session: session, state: state, sync: sync)
        .kitPane(.secondary)
    } pane: {
      CommitInspector(session: session, state: state)
    }
    .task(id: SyncKey(revision: session.revision, upstream: session.status?.upstream)) {
      sync = await SyncCommits.load(session)
    }
  }

  private struct SyncKey: Hashable {
    var revision: Int
    var upstream: String?
  }
}

/// The commits that wait to be pulled and pushed.
struct SyncCommits: Equatable {
  var toPull: [Commit] = []
  var toPush: [Commit] = []

  static func load(_ session: RepositorySession) async -> SyncCommits {
    guard session.status?.upstream != nil else { return SyncCommits() }
    let repository = session.repository
    let toPull = (try? await repository.log(LogQuery(revision: "HEAD..@{upstream}"), limit: 100)) ?? []
    let toPush = (try? await repository.log(LogQuery(revision: "@{upstream}..HEAD"), limit: 100)) ?? []
    return SyncCommits(toPull: toPull, toPush: toPush)
  }
}

/// The cards of commits, laid out once per change of the commits: which card each commit is in,
/// and the graph over them in that order.
private struct HistoryLayout {
  var toPull: [Commit] = []
  var toPush: [Commit] = []
  var rest: [Commit] = []
  var graph: [Commit.ID: GraphRow] = [:]
  var showsGraph = true
  /// How many people wrote the loaded commits, for the filter bar (counted here, not on every update).
  var authors = 0

  init() {}

  init(commits: [Commit], sync: SyncCommits, showsGraph: Bool) {
    self.showsGraph = showsGraph
    authors = Set(commits.map(\.authorEmail)).count
    guard showsGraph else {
      rest = commits
      return
    }
    toPull = sync.toPull
    let pushIDs = Set(sync.toPush.map(\.id))
    let pullIDs = Set(sync.toPull.map(\.id))
    // The list's own copies, which carry their refs as the log shows them.
    let byID = Dictionary(commits.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    toPull = sync.toPull.map { byID[$0.id] ?? $0 }
    toPush = sync.toPush.map { byID[$0.id] ?? $0 }
    rest = commits.filter { !pushIDs.contains($0.id) && !pullIDs.contains($0.id) }
    let ordered = toPull + toPush + rest
    let rows = CommitGraph.layout(ordered)
    graph = Dictionary(zip(ordered.map(\.id), rows), uniquingKeysWith: { a, _ in a })
  }

  var all: [Commit] { toPull + toPush + rest }

  /// Room for the widest row's lanes, capped so a busy graph doesn't push the text away.
  var graphWidth: CGFloat {
    let lanes = min(graph.values.lazy.map(\.width).max() ?? 1, CommitGraphCell.maxLanes)
    return CommitGraphCell.inset * 2 + CGFloat(max(lanes, 1) - 1) * CommitGraphCell.spacing
  }

  /// The lanes that run into `commit`'s row from above, for the gap and header before its card.
  func lanes(into commit: Commit?) -> [Lane] {
    guard let commit, let row = graph[commit.id] else { return [] }
    return (row.passing + row.incoming).map { Lane(index: $0.lane, color: $0.color) }
      + row.joining.map { Lane(index: $0.lane, color: $0.color) }
  }
}

/// A lane of the graph and its color index.
struct Lane: Hashable {
  var index: Int
  var color: Int
}

/// The cards: To pull, To push and the history, on the panel ground, with ↑/↓ to move the
/// selection. ⇧↑/⇧↓ and ⇧-click select several; the context menu squashes several that follow
/// one another.
private struct CommitList: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  let sync: SyncCommits
  @State private var layout = HistoryLayout()
  @State private var branchStart: Commit?
  @State private var tagTarget: Commit?
  @State private var resetTarget: Commit?
  @State private var squashRequest: SquashRequest?
  @State private var width: CGFloat = 800
  /// Where ⇧ ranges start: the commit last selected without ⇧.
  @State private var anchor: Commit.ID?
  @FocusState private var isFocused: Bool
  /// What the rows and the arrow keys do, filled as the list updates (`CommitRowActions`).
  @State private var rowActions = CommitRowActions()

  private struct LayoutKey: Hashable {
    var count: Int
    var first: Commit.ID?
    var last: Commit.ID?
    var sync: [Commit.ID]
    var showsGraph: Bool
  }

  private var layoutKey: LayoutKey {
    LayoutKey(
      count: session.commits.count, first: session.commits.first?.id, last: session.commits.last?.id,
      sync: (sync.toPull + sync.toPush).map(\.id), showsGraph: session.logQuery.showsGraph)
  }

  var body: some View {
    let actions = rowActions.configured(
      click: { click($0) }, menu: { AnyView(menu(for: $0)) },
      appeared: { commit, kind in
        if kind == .history, commit.id == session.commits.last?.id {
          Task { await session.loadMoreCommits() }
        }
      },
      move: { move($0, extending: $1) })
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          filterBar
          cards(actions)
        }
        .padding(.horizontal, KitMetrics.gutter)
        .padding(.bottom, KitMetrics.gutter)
      }
      .focusable()
      .focusEffectDisabled()
      .focused($isFocused)
      .modifier(CommitKeys(actions: actions))
      .onChange(of: state.selectedCommit) { _, id in
        guard let id else { return }
        // A clicked row is on screen already: a scroll, even one that doesn't move, updates the whole list again.
        if actions.clicked == id {
          actions.clicked = nil
          return
        }
        withKitAnimation { proxy.scrollTo(id) }
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .onChange(of: layoutKey, initial: true) {
      layout = HistoryLayout(commits: session.commits, sync: sync, showsGraph: session.logQuery.showsGraph)
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
          EmptyState(systemImage: "magnifyingglass", title: "No Results", message: "No commit matches “\(search)”.")
        } else {
          EmptyState(systemImage: "clock", title: "No Commits", message: "Commits you make appear here.")
        }
      }
    }
    .task(id: session.commits.first?.id) {
      if state.selectedCommit == nil { state.selectedCommit = layout.all.first?.id ?? session.commits.first?.id }
    }
    .kitSheet(item: $branchStart) { commit in
      NewBranchSheet(session: session, startPoint: commit.id)
    }
    .kitSheet(item: $tagTarget) { commit in
      NewTagSheet(session: session, commit: commit)
    }
    .kitSheet(item: $squashRequest) { request in
      SquashSheet(session: session, commits: request.commits) { select($0) }
    }
    .kitConfirmation(
      "Reset \(session.status?.branch ?? "HEAD") to \(resetTarget?.shortID ?? "")?",
      isPresented: .init(get: { resetTarget != nil }, set: { if !$0 { resetTarget = nil } }),
      message: "Later commits are removed from the branch. Their changes stay in the working tree, so you can commit them again.",
      systemImage: "arrow.uturn.backward", confirm: "Reset", role: nil
    ) {
      if let commit = resetTarget { Task { await session.reset(to: commit) } }
    }
  }

  // MARK: Filter

  private var filterBar: some View {
    HStack(spacing: 12) {
      KitSegmented(
        selection: .init(
          get: { session.logQuery.allBranches },
          set: { all in
            var query = session.logQuery
            query.allBranches = all
            session.logQuery = query
          }),
        options: [("All Branches", true), ("Current Branch", false)])
      Spacer()
      let authors = layout.authors
      Text(
        "\(session.commits.count)\(session.hasMoreCommits ? "+" : "") commit\(session.commits.count == 1 ? "" : "s") · \(authors) author\(authors == 1 ? "" : "s")"
      )
      .kitFont(.caption)
      .contentTransition(.numericText(value: Double(session.commits.count)))
      .animation(.kit, value: session.commits.count)
    }
    .padding(.horizontal, 4)
    .frame(height: 44)
  }

  // MARK: Cards

  /// To pull, To push and the history, each a card over lazy rows (the header, the commits and,
  /// while more load, the loading row), so a long history lays out only the rows on screen.
  @ViewBuilder
  private func cards(_ actions: CommitRowActions) -> some View {
    let layout = layout
    let upstream = session.status?.upstream ?? "the upstream"
    if !layout.toPull.isEmpty {
      let count = layout.toPull.count + 1
      CommitCardHeader(
        title: "To pull", count: Count(layout.toPull.count), meta: ["from \(upstream)", authors(layout.toPull)],
        systemImage: "arrow.down", hue: .gray, lanes: [], graphWidth: layout.graphWidth
      ) {
        Button("Pull", systemImage: "arrow.down") { Task { await session.pull() } }
          .buttonStyle(.kit)
          .controlSize(.small)
          .disabled(session.isBusy || GitSecurity.refusal(for: session.repository) != nil)
      }
      .kitCardSlice(0, of: count)
      rows(layout.toPull, layout: layout, kind: .toPull, cardSize: count, actions: actions)
      LaneGap(lanes: layout.lanes(into: layout.toPush.first ?? layout.rest.first), dashed: true)
    }
    if !layout.toPush.isEmpty {
      let count = layout.toPush.count + 1
      CommitCardHeader(
        title: "To push", count: Count(layout.toPush.count, .attention),
        meta: ["to \(upstream)", authors(layout.toPush)], systemImage: "arrow.up", hue: .accent,
        lanes: layout.lanes(into: layout.toPush.first), graphWidth: layout.graphWidth
      ) {
        Button("Push", systemImage: "arrow.up") { Task { await session.push() } }
          .buttonStyle(.kitPrimary)
          .controlSize(.small)
          .disabled(session.isBusy || GitSecurity.refusal(for: session.repository) != nil)
      }
      .kitCardSlice(0, of: count)
      rows(layout.toPush, layout: layout, kind: .toPush, cardSize: count, actions: actions)
      LaneGap(lanes: layout.lanes(into: layout.rest.first), dashed: false)
    }
    if !layout.rest.isEmpty || session.isLoadingCommits {
      let count = layout.rest.count + (session.isLoadingCommits ? 2 : 1)
      CommitCardHeader(
        title: historyTitle, count: nil, meta: historyMeta, systemImage: historyImage, hue: .accent,
        lanes: layout.lanes(into: layout.rest.first), graphWidth: layout.graphWidth
      ) {
        EmptyView()
      }
      .kitCardSlice(0, of: count)
      rows(layout.rest, layout: layout, kind: .history, cardSize: count, actions: actions)
      if session.isLoadingCommits {
        HStack(spacing: 8) {
          LiveIcon(systemImage: "clock", hue: .gray, status: .working, size: 18)
          Text("Loading older commits").kitFont(.caption)
        }
        .padding(.leading, layout.graphWidth + 8)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .kitCardSlice(count - 1, of: count)
      }
    }
  }

  private var historyTitle: String {
    if session.logQuery.search != nil { return "Results" }
    return session.status?.branch ?? session.status?.headOID.map { String($0.prefix(7)) } ?? "History"
  }

  private var historyImage: String {
    session.logQuery.search != nil ? "magnifyingglass" : "arrow.triangle.branch"
  }

  private var historyMeta: [String] {
    if let search = session.logQuery.search {
      let count = session.commits.count
      return ["\(count) commit\(count == 1 ? "" : "s") matching “\(search)”"]
    }
    var parts = [session.repository.url.lastPathComponent]
    if session.logQuery.allBranches { parts.append("all branches") }
    if let tag = session.tags.first { parts.append("\(tag.name) is the latest tag") }
    return parts
  }

  private func authors(_ commits: [Commit]) -> String {
    var seen = Set<String>()
    let names = commits.map(\.authorName).filter { seen.insert($0).inserted }
    return names.count > 2 ? "\(names[0]), \(names[1]) and \(names.count - 2) more" : names.joined(separator: ", ")
  }

  /// The commits as rows 1… of a card of `cardSize` rows (row 0 is its header).
  /// Each row takes the actions box rather than closures, so a selection change builds only the rows it changes.
  private func rows(
    _ commits: [Commit], layout: HistoryLayout, kind: CommitRow.Kind, cardSize: Int, actions: CommitRowActions
  ) -> some View {
    let headOID = session.status?.headOID
    let maxRefs = width < 720 ? 1 : 2
    return ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
      CommitRow(
        commit: commit, graph: layout.graph[commit.id], graphWidth: layout.graphWidth, kind: kind,
        isHead: commit.id == headOID, isUnpushed: kind == .toPush,
        isSelected: state.selectedCommit == commit.id || state.selectedCommits.contains(commit.id),
        isFocused: isFocused, maxRefs: maxRefs
      )
      .equatable()
      .modifier(CommitRowExtras(commit: commit, kind: kind, actions: actions))
      .kitCardSlice(index + 1, of: cardSize)
      .id(commit.id)
    }
  }

  /// A row's context menu: Squash for several selected commits that include it, else the commit's own.
  @ViewBuilder
  private func menu(for commit: Commit) -> some View {
    if state.selectedCommits.count > 1, state.selectedCommits.contains(commit.id) {
      selectionMenu()
    } else {
      contextMenu(for: commit)
    }
  }

  // MARK: Selection

  /// Moves the selection one row; with ⇧ it extends the selection instead.
  private func move(_ offset: Int, extending: Bool) -> KeyPress.Result {
    let commits = layout.all
    guard !commits.isEmpty else { return .ignored }
    let index = state.selectedCommit.flatMap { id in commits.firstIndex { $0.id == id } } ?? -1
    let next = commits[min(max(index + offset, 0), commits.count - 1)].id
    if extending { extendSelection(to: next) } else { select(next) }
    return .handled
  }

  /// Click selects one commit; ⇧-click selects every commit from the anchor to this one.
  private func click(_ commit: Commit) {
    rowActions.clicked = commit.id
    let flags = KitDesktop.modifierKeys
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
    let commits = layout.all
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
    if case .failure(let error) = run {
      // Why Squash is off, in the panel while nothing else is highlighted.
      KitMenuPreview((error as? GitError)?.message ?? error.localizedDescription)
    }
    Button("Squash \(selected.count) Commits…", systemImage: "arrow.triangle.merge") {
      if case .success(let commits) = run { squashRequest = SquashRequest(commits: commits) }
    }
    .kitMenuPreview(
      "Turns these \(selected.count) commits into one on \(session.status?.branch ?? "this branch"). You write its message first."
    ) {
      BranchPicture(.squash(commits: selected.count))
    }
    .disabled(session.isBusy || session.status?.operation != nil || (try? run.get()) == nil)
    Divider()
    Button("Copy SHAs", systemImage: "doc.on.doc") {
      KitPasteboard.copy(
        session.commits.filter { selected.contains($0.id) }.map(\.id).joined(separator: "\n"))
    }
  }

  @ViewBuilder
  private func contextMenu(for commit: Commit) -> some View {
    let branch = session.status?.branch ?? "HEAD"
    Button("Check Out", systemImage: "arrow.uturn.backward") { Task { await session.checkout(commit) } }
      .kitMenuPreview("Puts you on \(commit.shortID) without a branch.")
      .disabled(session.isBusy)
    Button("Revert Changes", systemImage: "arrow.uturn.left") { Task { await session.revert(commit) } }
      .kitMenuPreview("Makes a new commit on \(branch) that undoes the changes of \(commit.shortID).")
      .disabled(session.isBusy)
    Button("Cherry-Pick", systemImage: "arrow.right.doc.on.clipboard") { Task { await session.cherryPick(commit) } }
      .kitMenuPreview("Makes a new commit on \(branch) with the changes of \(commit.shortID).")
      .disabled(session.isBusy)
    Button("Reset to Here…", systemImage: "clock.arrow.circlepath") { resetTarget = commit }
      .kitMenuPreview(
        "Moves \(branch) to this commit. The commits after it leave \(branch); their changes stay in your files. It asks first."
      ) {
        BranchPicture(.reset(branch: branch))
      }
      .disabled(session.isBusy || commit.id == session.status?.headOID)
    Divider()
    CommitCreateItems(commit: commit, branchStart: $branchStart, tagTarget: $tagTarget)
  }
}


/// A card's header: the rich header, with the lanes that run on behind it.
private struct CommitCardHeader<Accessory: View>: View {
  let title: String
  let count: Count?
  let meta: [String]
  let systemImage: String
  let hue: Hue
  let lanes: [Lane]
  let graphWidth: CGFloat
  @ViewBuilder let accessory: () -> Accessory

  var body: some View {
    RichHeader(
      Text(title),
      // On the window's ground, so the lanes behind the header don't show through the tile.
      icon: {
        Tile(systemImage: systemImage, hue: hue, size: 24)
          .background(RoundedRectangle(cornerRadius: KitMetrics.radiusSmall, style: .continuous).fill(.kitWindow))
      },
      meta: { MetaLine(meta) },
      accessory: {
        HStack(spacing: 8) {
          if let count { count }
          accessory()
        }
      }
    )
    .background(alignment: .leading) { LaneLines(lanes: lanes, dashed: false).frame(width: graphWidth) }
  }
}

/// The gap between two cards, with the graph's lanes running through it.
private struct LaneGap: View {
  let lanes: [Lane]
  let dashed: Bool

  var body: some View {
    LaneLines(lanes: lanes, dashed: dashed)
      .frame(height: KitMetrics.gutter)
      .padding(.leading, KitMetrics.cardPadding)
  }
}

/// Lanes running straight down, top to bottom.
private struct LaneLines: View {
  let lanes: [Lane]
  let dashed: Bool

  var body: some View {
    Canvas { context, size in
      for lane in lanes {
        let x = CommitGraphCell.x(lane.index)
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(
          path, with: .color(CommitGraphCell.color(lane.color, in: context.environment)),
          style: CommitGraphCell.stroke(dashed: dashed))
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// What the history's rows and arrow keys do, in a box the list fills each time it updates: the rows, their menus and
/// the key handler hold the box rather than closures, so a new selection updates only the rows whose selection changed
/// (new closures made every row and its menu update, and a new key handler wrote the environment of the whole list).
@MainActor private final class CommitRowActions {
  var click: (Commit) -> Void = { _ in }
  var menu: (Commit) -> AnyView = { _ in AnyView(EmptyView()) }
  var appeared: (Commit, CommitRow.Kind) -> Void = { _, _ in }
  var move: (Int, Bool) -> KeyPress.Result = { _, _ in .ignored }
  /// The commit a click just selected: it's on screen, so the list doesn't scroll to it.
  var clicked: Commit.ID?

  func configured(
    click: @escaping (Commit) -> Void, menu: @escaping (Commit) -> AnyView,
    appeared: @escaping (Commit, CommitRow.Kind) -> Void, move: @escaping (Int, Bool) -> KeyPress.Result
  ) -> Self {
    self.click = click
    self.menu = menu
    self.appeared = appeared
    self.move = move
    return self
  }
}

/// ↑ and ↓ move the selection, ⇧ extends it.
private struct CommitKeys: ViewModifier {
  let actions: CommitRowActions

  func body(content: Content) -> some View {
    content.onKeyPress(keys: [.upArrow, .downArrow]) { [actions] press in
      actions.move(press.key == .downArrow ? 1 : -1, press.modifiers.contains(.shift))
    }
  }
}

/// A row's click, context menu and the history's next page as the last row comes in, from the box.
private struct CommitRowExtras: ViewModifier {
  let commit: Commit
  let kind: CommitRow.Kind
  let actions: CommitRowActions

  func body(content: Content) -> some View {
    content
      .onTapGesture { [actions, commit] in actions.click(commit) }
      .kitContextMenu { [actions, commit] in actions.menu(commit) }
      .onAppear { [actions, commit, kind] in actions.appeared(commit, kind) }
  }
}

/// One 46-point commit row: the graph with the author as the node, the message over the author,
/// date and short sha, and the refs at the end.
private struct CommitRow: View, Equatable {
  enum Kind { case toPull, toPush, history }

  let commit: Commit
  let graph: GraphRow?
  let graphWidth: CGFloat
  let kind: Kind
  let isHead: Bool
  let isUnpushed: Bool
  let isSelected: Bool
  let isFocused: Bool
  let maxRefs: Int
  @State private var isHovered = false

  nonisolated static func == (a: Self, b: Self) -> Bool {
    MainActor.assumeIsolated {
      a.commit == b.commit && a.graph == b.graph && a.graphWidth == b.graphWidth && a.kind == b.kind
        && a.isHead == b.isHead && a.isUnpushed == b.isUnpushed && a.isSelected == b.isSelected
        && a.isFocused == b.isFocused && a.maxRefs == b.maxRefs
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      ZStack(alignment: .leading) {
        if let graph {
          CommitGraphCell(row: graph, dashed: kind == .toPull)
        }
        CommitNode(
          commit: commit, kind: kind, isHead: isHead,
          laneHue: graph.map { CommitGraphCell.hue($0.color) } ?? .accent
        )
        .position(x: CommitGraphCell.x(graph?.column ?? 0), y: 23)
      }
      .frame(width: graphWidth, height: 46)
      VStack(alignment: .leading, spacing: 1) {
        Text(commit.subject)
          .fontWeight(isSelected && isFocused ? .medium : .regular)
          .lineLimit(1)
        HStack(spacing: 0) {
          if commit.parents.count > 1 {
            Image(systemName: "arrow.triangle.merge").padding(.trailing, 3)
            Text("Merge · ")
          }
          Text("\(commit.authorName) · \(commit.authorDate.kitFormatted(.dayAndTime)) · ")
          Text(commit.shortID).monospaced()
        }
        .kitFont(.caption)
        .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if !commit.refs.isEmpty {
        // The refs keep their room; the message gives way.
        RefChips(
          commit.refs.map(RefChip.Ref.init), maxVisible: maxRefs, meta: [commit.shortID, commit.subject]
        )
        .controlSize(.small)
        .padding(.leading, 8)
        .layoutPriority(1)
      }
    }
    .padding(.trailing, 8)
    .frame(height: 46)
    .background {
      let shape = RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous)
      if isSelected {
        Color.clear.kitSurface(.raised, cornerRadius: KitMetrics.radius)
      } else if isHovered {
        shape.fill(.kitHover)
      }
    }
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(.kitFast, value: isHovered)
    .animation(.kit, value: isSelected)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .help(commit.message)
  }
}

/// The author as the commit's node: HEAD rings it in the accent, a badge says it isn't pushed
/// (↑) or is only on the upstream (↓, faded); a merge is a small tile in its lane's color.
private struct CommitNode: View {
  let commit: Commit
  let kind: CommitRow.Kind
  let isHead: Bool
  let laneHue: Hue

  var body: some View {
    Group {
      if commit.parents.count > 1 {
        Tile(hue: laneHue, size: 20, shape: .circle) { Image(systemName: "arrow.triangle.merge") }
          .background(Circle().fill(.kitCard))
      } else {
        Avatar(name: commit.authorName, size: 24)
          .opacity(kind == .toPull ? 0.55 : 1)
          .background(Circle().fill(.kitCard))
      }
    }
    .overlay {
      if isHead { Circle().strokeBorder(.kitAccent, lineWidth: 2).padding(-4) }
    }
    .overlay(alignment: .bottomTrailing) {
      if kind != .history {
        Image(systemName: kind == .toPush ? "arrow.up" : "arrow.down")
          .font(.system(size: 7, weight: .heavy))
          .foregroundStyle(.white)
          .frame(width: 12, height: 12)
          .background(Circle().fill(kind == .toPush ? AnyShapeStyle(.kitAccent) : AnyShapeStyle(Hue.gray.fill)))
          .background(Circle().fill(.kitCard).padding(-1.5))
          .offset(x: 4, y: 4)
      }
    }
    .help("\(commit.authorName) <\(commit.authorEmail)>")
  }
}

/// A row's slice of the branch graph: lines through the row and into its node. Rows sit edge to
/// edge, so the slices join into continuous lines.
struct CommitGraphCell: View {
  let row: GraphRow
  var dashed = false

  static let maxLanes = 8
  static let spacing: CGFloat = 22
  static let inset: CGFloat = 18
  private static let palette: [Hue] = [.accent, .orange, .purple, .teal, .pink, .green, .indigo, .brown]

  static func x(_ lane: Int) -> CGFloat { inset + CGFloat(min(lane, maxLanes - 1)) * spacing }
  static func hue(_ index: Int) -> Hue { palette[index % palette.count] }
  static func color(_ index: Int, in environment: EnvironmentValues) -> Color {
    hue(index).fill.resolve(in: environment)
  }
  static func stroke(dashed: Bool) -> StrokeStyle {
    StrokeStyle(lineWidth: 2, lineCap: dashed ? .butt : .round, dash: dashed ? [3, 3] : [])
  }

  var body: some View {
    Canvas { context, size in
      let mid = size.height / 2
      func stroke(_ path: Path, _ color: Int) {
        context.stroke(path, with: .color(Self.color(color, in: context.environment)), style: Self.stroke(dashed: dashed))
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
              to: end, control1: CGPoint(x: start.x, y: middle), control2: CGPoint(x: end.x, y: middle))
          }
        }
      }
      let node = CGPoint(x: Self.x(row.column), y: mid)
      for edge in row.passing {
        stroke(curve(from: CGPoint(x: Self.x(edge.lane), y: 0), to: CGPoint(x: Self.x(edge.lane), y: size.height)), edge.color)
      }
      for join in row.joining {
        stroke(curve(from: CGPoint(x: Self.x(join.lane), y: 0), to: CGPoint(x: Self.x(join.target), y: size.height)), join.color)
      }
      for edge in row.incoming {
        stroke(curve(from: CGPoint(x: Self.x(edge.lane), y: 0), to: node), edge.color)
      }
      for edge in row.outgoing {
        stroke(curve(from: node, to: CGPoint(x: Self.x(edge.lane), y: size.height)), edge.color)
      }
    }
    .accessibilityHidden(true)
  }
}

extension RefChip.Ref {
  /// The kit's ref for a GitKit ref label.
  init(_ label: RefLabel) {
    let kind: RefChip.Kind =
      switch label.kind {
      case .head: .head
      case .localBranch: .branch
      case .remoteBranch: .remote
      case .tag, .other: .tag
      }
    self.init(name: label.name, kind: kind, isCurrent: label.isCurrent)
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
  @Environment(\.kitDismiss) private var dismiss
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
    let isValid = !summary.trimmingCharacters(in: .whitespaces).isEmpty && !session.isBusy
    KitSheet(
      title: "Squash \(commits.count) Commits",
      meta: commits.last.map { oldest in
        "\(oldest.shortID) … \(commits.first?.shortID ?? "") become one commit by \(oldest.authorName)."
      },
      systemImage: "square.stack.3d.down.right", hue: .purple, width: 520
    ) {
      FormCard {
        FormRow("Summary", systemImage: "character.cursor.ibeam", field: TextField("Summary", text: $summary))
        FormRow(
          "Description", systemImage: "text.alignleft",
          field: KitMultilineField("Description", text: $details, lines: 4...12))
      }
      if !commits.allSatisfy(session.isUnpushed) {
        Banner(
          "Some of these commits are already pushed.",
          message: "Afterwards, Force Push replaces them on the remote.",
          systemImage: "exclamationmark.triangle", hue: .orange)
      }
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
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
      .buttonStyle(.kitPrimary)
      // Return starts a new line in the description.
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(!isValid)
    }
  }
}
