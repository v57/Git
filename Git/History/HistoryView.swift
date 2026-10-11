import GitKit
import SwiftUI

/// Paged commit history with search by message, author or sha.
struct HistoryView: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  @State private var searchText = ""
  @State private var searchField: LogQuery.SearchField = .message

  var body: some View {
    List(selection: $state.selectedCommit) {
      ForEach(session.commits) { commit in
        CommitRow(commit: commit)
          .tag(commit.id)
          .onAppear {
            if commit.id == session.commits.last?.id {
              Task { await session.loadMoreCommits() }
            }
          }
      }
      if session.isLoadingCommits {
        HStack {
          Spacer()
          ProgressView().controlSize(.small)
          Spacer()
        }
      }
    }
    .overlay {
      if session.commits.isEmpty && !session.isLoadingCommits {
        if session.logQuery.search != nil {
          ContentUnavailableView.search(text: searchText)
        } else {
          ContentUnavailableView("No Commits", systemImage: "clock")
        }
      }
    }
    .searchable(text: $searchText, placement: .sidebar, prompt: "Search history")
    .searchScopes($searchField) {
      Text("Message").tag(LogQuery.SearchField.message)
      Text("Author").tag(LogQuery.SearchField.author)
      Text("SHA").tag(LogQuery.SearchField.sha)
    }
    .onSubmit(of: .search) { applySearch() }
    .onChange(of: searchField) { if !searchText.isEmpty { applySearch() } }
    .onChange(of: searchText) { _, text in if text.isEmpty { applySearch() } }
    .contextMenu(forSelectionType: Commit.ID.self) { ids in
      if ids.count == 1, let id = ids.first {
        Button("Copy SHA") { copy(id) }
        if let commit = session.commits.first(where: { $0.id == id }) {
          Button("Copy Message") { copy(commit.message) }
          Divider()
          NewBranchButton(session: session, startPoint: commit.id, title: "New Branch from \(commit.shortID)…")
        }
      }
    }
  }

  private func applySearch() {
    let text = searchText.trimmingCharacters(in: .whitespaces)
    session.logQuery = LogQuery(search: text.isEmpty ? nil : text, searchField: searchField)
  }

  private func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  }
}

private struct CommitRow: View {
  let commit: Commit

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        ForEach(commit.refs, id: \.self) { ref in
          RefBadge(ref: ref)
        }
        Text(commit.subject)
          .lineLimit(1)
      }
      HStack(spacing: 6) {
        Text(commit.authorName)
          .lineLimit(1)
        Text(commit.authorDate, format: .relative(presentation: .named))
        Spacer(minLength: 4)
        Text(commit.shortID)
          .font(.caption.monospaced())
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }
}

struct RefBadge: View {
  let ref: RefLabel

  var body: some View {
    Text(ref.name)
      .font(.caption2.weight(ref.isCurrent ? .bold : .medium))
      .lineLimit(1)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .foregroundStyle(color)
      .background(color.opacity(0.15), in: .capsule)
      .fixedSize()
  }

  private var color: Color {
    switch ref.kind {
    case .localBranch, .head: .accentColor
    case .remoteBranch: .purple
    case .tag: .orange
    case .other: .secondary
    }
  }
}
