import GitKit
import SwiftUI

/// A commit: message and metadata, the files it changed, and the diff of the selected file.
struct CommitDetailView: View {
  let session: RepositorySession
  let commit: Commit
  @Bindable var state: RepositoryViewState
  @Environment(\.colorScheme) private var colorScheme
  @State private var files: [CommitFile]?
  @State private var loaded: LoadedDiff?
  @State private var selection: Set<Int> = []

  private var selectedFile: CommitFile? {
    files?.first { $0.id == state.selectedCommitFile }
  }

  var body: some View {
    VStack(spacing: 0) {
      CommitHeader(commit: commit)
      Divider()
      HSplitView {
        fileList
          .frame(minWidth: 180, idealWidth: 240, maxWidth: 420)
        diffArea
          .frame(minWidth: 300, maxWidth: .infinity)
      }
    }
    .task { await loadFiles() }
    .task(id: DiffKey(file: selectedFile, dark: colorScheme == .dark)) { await loadDiff() }
  }

  private struct DiffKey: Hashable {
    var file: CommitFile?
    var dark: Bool
  }

  private var fileList: some View {
    List(selection: $state.selectedCommitFile) {
      ForEach(files ?? []) { file in
        HStack(spacing: 6) {
          ChangeKindBadge(kind: file.kind)
          VStack(alignment: .leading, spacing: 0) {
            Text(file.fileName).lineLimit(1)
            if !file.directory.isEmpty {
              Text(file.directory)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            }
          }
        }
        .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
        .tag(file.id)
      }
    }
    .overlay {
      if files == nil { ProgressView() }
    }
  }

  @ViewBuilder
  private var diffArea: some View {
    if let loaded, loaded.target.path == selectedFile?.path {
      if loaded.diff.hunks.isEmpty {
        DiffPlaceholder(diff: loaded.diff)
      } else {
        DiffView(content: loaded, selection: $selection)
      }
    } else if selectedFile == nil {
      ContentUnavailableView("No File Selected", systemImage: "doc.text")
    } else {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func loadFiles() async {
    do {
      let files = try await session.repository.changedFiles(in: commit)
      self.files = files
      if selectedFile == nil { state.selectedCommitFile = files.first?.id }
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

private struct CommitHeader: View {
  let commit: Commit

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(commit.subject)
        .font(.title3.weight(.semibold))
        .textSelection(.enabled)
      if !commit.body.isEmpty {
        ScrollView {
          Text(commit.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 120)
        .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 16) {
        Label {
          Text("\(commit.authorName) <\(commit.authorEmail)>")
        } icon: {
          Image(systemName: "person")
        }
        Label {
          Text(commit.authorDate, format: .dateTime.year().month().day().hour().minute())
        } icon: {
          Image(systemName: "calendar")
        }
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(commit.id, forType: .string)
        } label: {
          Label(commit.shortID, systemImage: "doc.on.doc")
            .font(.callout.monospaced())
        }
        .buttonStyle(.borderless)
        .help("Copy \(commit.id)")
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      if commit.committerName != commit.authorName {
        Text("Committed by \(commit.committerName)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if commit.isMerge {
        Text("Merge of \(commit.parents.map { String($0.prefix(7)) }.joined(separator: ", ")) — showing changes against the first parent")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
