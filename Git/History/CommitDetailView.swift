import GitKit
import SwiftUI

/// The selected commit, as in the design's inspector: refs, message, author and sha, actions,
/// the changed files with their line counts, and the selected file's diff.
struct CommitInspector: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState

  var body: some View {
    Group {
      if let id = state.selectedCommit, let commit = session.commits.first(where: { $0.id == id }) {
        CommitDetail(session: session, commit: commit, state: state)
          .id(commit.id)
          .transition(.page)
      } else {
        ContentUnavailableView("No Commit Selected", systemImage: "clock")
          .transition(.opacity)
      }
    }
    .animation(.app, value: state.selectedCommit)
    .frame(maxHeight: .infinity)
    .background(Color.primary.opacity(0.012))
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
    VStack(spacing: 0) {
      header
      Divider()
      fileList
      diffPreview
    }
    .task { await loadFiles() }
    .task(id: DiffKey(file: selectedFile, dark: colorScheme == .dark)) { await loadDiff() }
    .confirmationDialog(
      "Check out \(commit.shortID)?", isPresented: $confirmCheckout, titleVisibility: .visible
    ) {
      Button("Check Out") { Task { await session.checkout(commit) } }
    } message: {
      Text("You'll be on this commit without a branch. Create a branch to keep work you do here.")
    }
    .confirmationDialog(
      "Revert \(commit.shortID)?", isPresented: $confirmRevert, titleVisibility: .visible
    ) {
      Button("Revert") { Task { await session.revert(commit) } }
    } message: {
      Text("A new commit undoes the changes of “\(commit.subject)”.")
    }
    .sheet(item: $branchStart) { commit in NewBranchSheet(session: session, startPoint: commit.id) }
    .sheet(item: $tagTarget) { commit in NewTagSheet(session: session, commit: commit) }
    .sheet(isPresented: $showsFullDiff) { fullDiff }
  }

  private struct DiffKey: Hashable {
    var file: CommitFile?
    var dark: Bool
  }

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !commit.refs.isEmpty {
        HStack(spacing: 6) {
          ForEach(commit.refs.prefix(4), id: \.self) { ref in RefPill(ref: ref, height: 20) }
        }
      }
      Text(commit.subject)
        .font(.system(size: 18, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      if !commit.body.isEmpty {
        ScrollView {
          Text(commit.body)
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 110)
        .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 10) {
        Avatar(name: commit.authorName, size: 32)
        VStack(alignment: .leading, spacing: 1) {
          Text(commit.authorName).fontWeight(.semibold)
          Text(commit.authorDate.historyFormatted)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .help("\(commit.authorName) <\(commit.authorEmail)>")
        Spacer()
        Button {
          copyToPasteboard(commit.id)
        } label: {
          HStack(spacing: 6) {
            Text(commit.shortID)
            Image(systemName: "square.on.square")
              .resizable()
              .scaledToFit()
              .frame(width: 13, height: 13)
              .foregroundStyle(.secondary)
          }
          .font(.system(size: 12, design: .monospaced))
        }
        .buttonStyle(.design(size: .small, padding: 8))
        .help("Copy \(commit.id)")
        .accessibilityLabel("Copy commit hash")
      }
      .padding(.top, 2)
      HStack(spacing: 8) {
        Button("Check Out") { confirmCheckout = true }
          .buttonStyle(.design)
          .disabled(session.isBusy || commit.id == session.status?.headOID)
        Button("Revert…") { confirmRevert = true }
          .buttonStyle(.design)
          .disabled(session.isBusy)
        Button("Cherry-Pick") { Task { await session.cherryPick(commit) } }
          .buttonStyle(.design)
          .disabled(session.isBusy || commit.id == session.status?.headOID)
        Menu {
          Button("Create Branch from Commit…") { branchStart = commit }
          Button("Create Tag…") { tagTarget = commit }
          Divider()
          Button("Copy SHA") { copyToPasteboard(commit.id) }
          Button("Copy Message") { copyToPasteboard(commit.message) }
        } label: {
          DesignButtonLabel(width: 32) {
            Image(systemName: "ellipsis")
          }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions")
      }
      .padding(.top, 4)
    }
    .padding(.horizontal, 24)
    .padding(.top, 20)
    .padding(.bottom, 18)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Files

  private var fileList: some View {
    let files = files ?? []
    let added = files.compactMap(\.lines?.added).reduce(0, +)
    let removed = files.compactMap(\.lines?.removed).reduce(0, +)
    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(files.count == 1 ? "1 File Changed" : "\(files.count) Files Changed")
          .fontWeight(.semibold)
        Spacer()
        LineCountText(counts: LineCounts(added: added, removed: removed), font: .system(size: 12, design: .monospaced))
      }
      .padding(.bottom, 4)
      ScrollView {
        VStack(spacing: 0) {
          ForEach(files) { file in
            let isSelected = file.id == selectedFile?.id
            Button {
              state.selectedCommitFile = file.id
            } label: {
              HStack(spacing: 10) {
                ChangeKindBadge(kind: file.kind)
                (Text(file.fileName).fontWeight(.medium)
                  + Text("  \(file.directory)").font(.system(size: 12)).foregroundStyle(.secondary))
                  .lineLimit(1)
                  .truncationMode(.tail)
                Spacer(minLength: 4)
                LineCountText(counts: file.lines)
              }
              .padding(.horizontal, 8)
              .frame(height: 30)
              .background(
                Color.primary.opacity(isSelected ? 0.06 : 0), in: .rect(cornerRadius: 7, style: .continuous)
              )
              .animation(.app, value: isSelected)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
          }
        }
      }
      .frame(maxHeight: min(CGFloat(files.count) * 30, 210))
      .padding(.horizontal, -8)
    }
    .padding(.horizontal, 24)
    .padding(.top, 16)
    .padding(.bottom, 12)
    .overlay {
      if self.files == nil { ProgressView().controlSize(.small) }
    }
  }

  // MARK: Diff

  private var diffPreview: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(selectedFile?.path ?? "")
          .font(.system(size: 12, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.head)
        Spacer()
        Button("Open Diff") { showsFullDiff = true }
          .buttonStyle(.link)
          .font(.system(size: 12, weight: .medium))
          .disabled(loaded == nil)
      }
      Group {
        if let loaded, loaded.target.path == selectedFile?.path {
          Group {
            if loaded.diff.hunks.isEmpty {
              DiffPlaceholder(diff: loaded.diff)
            } else {
              DiffView(content: loaded, selection: $selection)
            }
          }
          .id(loaded.target)
          .transition(.opacity)
        } else if files?.isEmpty == true {
          ContentUnavailableView("No Changes", systemImage: "equal")
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .animation(.app, value: loaded?.target)
      .clipShape(.rect(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
    .padding(.horizontal, 24)
    .padding(.top, 4)
    .padding(.bottom, 24)
  }

  private var fullDiff: some View {
    VStack(spacing: 0) {
      HStack {
        Text(loaded?.diff.path ?? "")
          .font(.system(size: 13, design: .monospaced))
        LineCountText(counts: loaded.map { LineCounts(added: $0.diff.additions, removed: $0.diff.deletions) })
        Spacer()
        Button("Done") { showsFullDiff = false }
          .keyboardShortcut(.defaultAction)
      }
      .padding(12)
      Divider()
      if let loaded {
        DiffView(content: loaded, selection: $selection)
      }
    }
    .frame(minWidth: 900, minHeight: 620)
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
