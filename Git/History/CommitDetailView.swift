import ComponentKit
import GitKit
import SwiftUI

/// The selected commit, as in the design's inspector: the message with the refs, the author and
/// sha, the changed files with their line counts, the actions, and the selected file's hunks.
struct CommitInspector: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState

  var body: some View {
    Group {
      if let id = state.selectedCommit, let commit = session.commits.first(where: { $0.id == id }) {
        CommitDetail(session: session, commit: commit, state: state)
          .id(commit.id)
          .transition(.detail)
      } else {
        EmptyState(systemImage: "clock", title: "No Commit Selected", message: "Pick a commit to see what it changed.")
          .kitPane(.secondary)
          .transition(.opacity)
      }
    }
    .animation(.kit, value: state.selectedCommit)
    .frame(maxHeight: .infinity)
  }
}

private struct CommitDetail: View {
  let session: RepositorySession
  let commit: Commit
  @Bindable var state: RepositoryViewState
  @Environment(\.colorScheme) private var colorScheme
  @State private var files: [CommitFile]?
  @State private var loaded: LoadedDiff?
  @State private var selection: Set<Int> = []
  @State private var confirmCheckout = false
  @State private var confirmRevert = false
  @State private var branchStart: Commit?
  @State private var tagTarget: Commit?
  @State private var showsFullDiff = false

  private var selectedFile: CommitFile? {
    files?.first { $0.id == state.selectedCommitFile } ?? files?.first
  }

  var body: some View {
    KitInspector(width: nil) {
      InspectorHeader(commit.subject, meta: headerMeta, systemImage: "smallcircle.filled.circle", hue: .blue) {
        ForEach(RefChip.Ref.arranged(commit.refs.map(RefChip.Ref.init))) { ref in
          RefChip(ref, maxWidth: nil).controlSize(.small)
        }
      }
      author
      fileList
      ActionBar {
        Button("Check Out") { confirmCheckout = true }
          .disabled(session.isBusy || commit.id == session.status?.headOID)
        Button("Revert…") { confirmRevert = true }
          .disabled(session.isBusy)
        Button("Cherry-Pick") { Task { await session.cherryPick(commit) } }
          .disabled(session.isBusy || commit.id == session.status?.headOID)
        Menu {
          Button("Create Branch from Commit…") { branchStart = commit }
          Button("Create Tag…") { tagTarget = commit }
          Divider()
          Button("Copy SHA") { copyToPasteboard(commit.id) }
          Button("Copy Message") { copyToPasteboard(commit.message) }
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions")
      }
      diffPreview
    }
    .task { await loadFiles() }
    .task(id: DiffKey(file: selectedFile, dark: colorScheme == .dark)) { await loadDiff() }
    .kitConfirmation(
      "Check out \(commit.shortID)?", isPresented: $confirmCheckout,
      message: "You'll be on this commit without a branch. Create a branch to keep work you do here.",
      systemImage: "arrow.uturn.backward", confirm: "Check Out", role: nil
    ) {
      Task { await session.checkout(commit) }
    }
    .kitConfirmation(
      "Revert \(commit.shortID)?", isPresented: $confirmRevert,
      message: "A new commit undoes the changes of “\(commit.subject)”.",
      systemImage: "arrow.uturn.backward", confirm: "Revert", role: nil
    ) {
      Task { await session.revert(commit) }
    }
    .sheet(item: $branchStart) { commit in NewBranchSheet(session: session, startPoint: commit.id) }
    .sheet(item: $tagTarget) { commit in NewTagSheet(session: session, commit: commit) }
    .sheet(isPresented: $showsFullDiff) { fullDiff }
  }

  private var headerMeta: [String] {
    let count = files?.count
    return [commit.shortID, count.map { $0 == 1 ? "1 file changed" : "\($0) files changed" } ?? ""]
  }

  // MARK: Author

  private var author: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Avatar(name: commit.authorName, size: 32)
        VStack(alignment: .leading, spacing: 1) {
          Text(commit.authorName).kitFont(.headline)
          Text(commit.authorDate.historyFormatted).kitFont(.caption)
        }
        .help("\(commit.authorName) <\(commit.authorEmail)>")
        Spacer()
        Button(commit.shortID, systemImage: "doc.on.doc") { copyToPasteboard(commit.id) }
          .buttonStyle(.kitPlain)
          .monospaced()
          .help("Copy \(commit.id)")
          .accessibilityLabel("Copy commit hash")
      }
      if !commit.body.isEmpty {
        ScrollView {
          Text(commit.body)
            .foregroundStyle(.kitSecondary)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 110)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(10)
    .kitSurface(.card)
  }

  // MARK: Files

  private var fileList: some View {
    let files = files ?? []
    let added = files.compactMap(\.lines?.added).reduce(0, +)
    let removed = files.compactMap(\.lines?.removed).reduce(0, +)
    return KitSection(
      Text("Files"),
      content: {
        ForEach(files) { file in
          FileRow(
            file: file, isSelected: file.id == selectedFile?.id
          )
          .onTapGesture { state.selectedCommitFile = file.id }
        }
      },
      icon: {
        LiveIcon(systemImage: "doc.text", hue: .green, status: self.files == nil ? .working : .idle)
      },
      meta: {
        HStack(spacing: 6) {
          Text(files.count == 1 ? "1 changed" : "\(files.count) changed")
          if !files.isEmpty { Diffstat(added: added, removed: removed) }
        }
      },
      accessory: { EmptyView() })
  }

  // MARK: Diff

  private var diffPreview: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(selectedFile?.path ?? "")
          .kitFont(.mono)
          .lineLimit(1)
          .truncationMode(.head)
        Spacer()
        Button("Open Diff") { showsFullDiff = true }
          .buttonStyle(.kitPlain)
          .disabled(loaded == nil)
      }
      .padding(.horizontal, 6)
      Group {
        if let loaded, loaded.target.path == selectedFile?.path {
          Group {
            if loaded.diff.hunks.isEmpty {
              DiffPlaceholder(diff: loaded.diff)
            } else {
              HunkCards(content: loaded, selection: $selection)
            }
          }
          .id(loaded.target)
          .transition(.opacity)
        } else if files?.isEmpty == true {
          EmptyState(systemImage: "equal", title: "No Changes")
        } else {
          LiveIcon(systemImage: "doc.text", hue: .gray, status: .working, size: 24)
            .frame(maxWidth: .infinity, minHeight: 120)
        }
      }
      .animation(.kit, value: loaded?.target)
    }
  }

  private var fullDiff: some View {
    KitSheet(
      title: loaded?.diff.path ?? "", meta: loaded.map { "+\($0.diff.additions) −\($0.diff.deletions)" },
      systemImage: "doc.text", width: 900, onClose: { showsFullDiff = false }
    ) {
      if let loaded {
        ScrollView { HunkCards(content: loaded, selection: $selection) }
          .frame(minHeight: 560)
      }
    }
  }

  private struct DiffKey: Hashable {
    var file: CommitFile?
    var dark: Bool
  }

  private func loadFiles() async {
    do {
      let files = try await session.repository.changedFiles(in: commit)
      self.files = files
      if !files.contains(where: { $0.id == state.selectedCommitFile }) {
        state.selectedCommitFile = files.first?.id
      }
    } catch {
      files = []
      session.report(error, title: "Couldn't load the commit")
    }
  }

  private func loadDiff() async {
    selection = []
    guard let file = selectedFile else {
      loaded = nil
      return
    }
    let target = DiffTarget.commit(
      sha: commit.id, parent: commit.parents.first, path: file.path,
      originalPath: file.originalPath)
    do {
      let result = try await LoadedDiff.load(
        target, repository: session.repository, isDark: colorScheme == .dark)
      guard !Task.isCancelled else { return }
      loaded = result
    } catch {
      guard !Task.isCancelled else { return }
      session.report(error, title: "Couldn't load the diff")
    }
  }
}

/// A changed file in the inspector: its change's tile, name and folder, and its line counts.
private struct FileRow: View {
  let file: CommitFile
  let isSelected: Bool
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 8) {
      ChangeKindBadge(kind: file.kind)
      (Text(file.fileName).fontWeight(isSelected ? .medium : .regular)
        + Text("  \(file.directory)").foregroundStyle(.kitSecondary).font(.system(size: 11)))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 4)
      if let lines = file.lines {
        Diffstat(added: lines.added, removed: lines.removed)
      } else {
        Text("binary").kitFont(.caption)
      }
    }
    .padding(.horizontal, 6)
    .frame(height: 32)
    .background {
      if isSelected {
        Color.clear.kitSurface(.raised, cornerRadius: KitMetrics.radius)
      } else if isHovered {
        RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous).fill(.kitHover)
      }
    }
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(.kit, value: isSelected)
    .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}
