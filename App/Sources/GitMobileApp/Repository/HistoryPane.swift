import ComponentKit
import GitKit
import GitUI
import SwiftUI

/// History: the current branch's commits, newest first, a page at a time as the list scrolls; each its subject,
/// author and date, short id and the branches and tags on it. A tap opens the commit.
struct HistoryPane: View {
  let model: RepositoryModel

  var body: some View {
    if model.commits.isEmpty {
      if model.isLoadingCommits {
        EmptyState(systemImage: "clock", title: "Reading History", status: .working)
      } else {
        EmptyState(systemImage: "clock", title: "No Commits Yet", message: "Commit your changes to start the history.")
      }
    } else {
      ScrollView {
        KitSection(
          model.status?.branch ?? "History", meta: meta, systemImage: "clock", hue: .indigo
        ) {
          LazyVStack(spacing: 0) {
            ForEach(model.commits) { commit in
              NavigationLink(value: commit) {
                CommitRow(commit: commit, isUnpushed: isUnpushed(commit))
              }
              .buttonStyle(.plain)
              .onAppear {
                if commit.id == model.commits.last?.id { Task { await model.loadMoreCommits() } }
              }
            }
          }
          if model.isLoadingCommits {
            LiveIcon(systemImage: "clock", hue: .gray, status: .working)
              .frame(maxWidth: .infinity)
              .padding(10)
          }
        }
        .kitSticky()
        .padding(.horizontal, KitMetrics.gutter + 4)
        .padding(.bottom, 24)
      }
      .refreshable { await model.refresh() }
    }
  }

  private var meta: [String] {
    let count = model.commits.count
    let shown = model.hasMoreCommits ? "\(count)+ commits" : count == 1 ? "1 commit" : "\(count) commits"
    guard let ahead = model.status?.ahead, ahead > 0 else { return [shown] }
    return [shown, "\(ahead) to push"]
  }

  /// The commits before the upstream's tip: the first `ahead` of the current branch.
  private func isUnpushed(_ commit: Commit) -> Bool {
    guard let ahead = model.status?.ahead, ahead > 0,
      let index = model.commits.firstIndex(where: { $0.id == commit.id })
    else { return false }
    return index < ahead
  }
}

/// A commit: its subject over author and date, the short id, and its refs as chips.
struct CommitRow: View {
  let commit: Commit
  var isUnpushed = false

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Avatar(name: commit.authorName, size: 28)
      VStack(alignment: .leading, spacing: 3) {
        Text(commit.subject)
          .kitFont(.body)
          .lineLimit(2)
        HStack(spacing: 6) {
          Text(commit.authorName).lineLimit(1)
          Text("·").foregroundStyle(.kitTertiary)
          Text(commit.authorDate.historyFormatted).lineLimit(1)
          if isUnpushed {
            Image(systemName: "arrow.up")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(Hue.orange.fill)
              .accessibilityLabel("Not pushed")
          }
        }
        .kitFont(.caption)
        .foregroundStyle(.kitSecondary)
        let refs = commit.refs.filter { $0.kind != .head }
        if !refs.isEmpty {
          HStack(spacing: 4) {
            ForEach(refs.prefix(3), id: \.name) { ref in
              RefChip(name: ref.name, kind: ref.kind == .tag ? .tag : ref.kind == .remoteBranch ? .remote : .branch,
                isCurrent: ref.isCurrent, maxWidth: 140)
            }
          }
        }
      }
      Spacer(minLength: 4)
      Text(commit.shortID)
        .kitFont(.monoSmall)
        .foregroundStyle(.kitTertiary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .contentShape(Rectangle())
  }
}

/// A commit pushed from History: its message, author, id and parents, then the files it changed (each a push to its
/// diff).
struct CommitScreen: View {
  let model: RepositoryModel
  let commit: Commit
  @State private var files: [CommitFile]?
  @State private var error: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: KitMetrics.gutter) {
        VStack(alignment: .leading, spacing: 8) {
          Text(commit.subject)
            .font(.system(size: 17, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
          if !commit.body.isEmpty {
            Text(commit.body)
              .kitFont(.body)
              .fixedSize(horizontal: false, vertical: true)
          }
          HStack(spacing: 8) {
            Avatar(name: commit.authorName, size: 22)
            Text("\(commit.authorName) · \(commit.authorDate.historyFormatted)")
              .kitFont(.caption)
              .foregroundStyle(.kitSecondary)
          }
          Text(commit.id)
            .kitFont(.monoSmall)
            .foregroundStyle(.kitTertiary)
        }
        .textSelection(.enabled)
        .padding(KitMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kitSurface(.card)

        if let files {
          KitSection("Files", meta: meta(files), systemImage: "doc.on.doc", hue: .blue) {
            ForEach(files) { file in
              NavigationLink(
                value: DiffRoute(
                  target: .commit(
                    sha: commit.id, parent: commit.parents.first, path: file.path, originalPath: file.originalPath),
                  change: nil, kind: file.kind)
              ) {
                CommitFileRow(file: file)
              }
              .buttonStyle(.plain)
            }
          }
        } else if let error {
          Banner("Couldn’t List the Files", message: error, systemImage: "exclamationmark.triangle", hue: .red)
        } else {
          LiveIcon(systemImage: "doc.on.doc", hue: .gray, status: .working).frame(maxWidth: .infinity)
        }
      }
      .padding(.horizontal, KitMetrics.gutter + 4)
      .padding(.vertical, 8)
    }
    .background(.kitWindow)
    .kitPane(.content)
    .kitToolbar(commit.shortID, title: {
      KitTitle(commit.subject, meta: [commit.shortID, commit.authorDate.historyFormatted], systemImage: "smallcircle.filled.circle", hue: .indigo)
    }) {}
    .navigationBarBackButtonHidden(true)
    .task {
      do {
        files = try await model.backend?.changedFiles(in: commit) ?? []
      } catch {
        self.error = RepositoryModel.describe(error)
      }
    }
  }

  private func meta(_ files: [CommitFile]) -> [String] {
    let added = files.compactMap { $0.lines?.added }.reduce(0, +)
    let removed = files.compactMap { $0.lines?.removed }.reduce(0, +)
    return [files.count == 1 ? "1 file" : "\(files.count) files", "+\(added) −\(removed)"]
  }
}

/// A file a commit changed: its status, name over folder and line counts.
struct CommitFileRow: View {
  let file: CommitFile

  var body: some View {
    HStack(spacing: 10) {
      ChangeKindBadge(kind: file.kind, size: 20)
      VStack(alignment: .leading, spacing: 1) {
        Text(file.fileName).kitFont(.body).lineLimit(1).truncationMode(.middle)
        if let folder = file.originalPath.map({ "from \($0)" }) ?? (file.directory.isEmpty ? nil : file.directory) {
          Text(folder).kitFont(.caption).foregroundStyle(.kitSecondary).lineLimit(1).truncationMode(.head)
        }
      }
      Spacer(minLength: 4)
      if let lines = file.lines { Diffstat(added: lines.added, removed: lines.removed) }
      Image(systemName: "chevron.right")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.kitTertiary)
    }
    .padding(.horizontal, 10)
    .frame(minHeight: 48)
    .contentShape(Rectangle())
  }
}
