import GitKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Repositories grouped by the folder they were imported from. Dropping a folder (or picking one
/// with Add Folder) adds every git repository inside it.
struct SidebarView: View {
  @Environment(RepositoryLibrary.self) private var library
  @Environment(\.modelContext) private var context
  @Query(sort: \SavedRepository.name, order: .forward) private var repositories: [SavedRepository]
  @Binding var selection: String?
  @State private var isDropTargeted = false

  private var groups: [(group: String, repositories: [SavedRepository])] {
    Dictionary(grouping: repositories, by: \.group)
      .map { ($0.key, $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
      .sorted { ($0.group as NSString).lastPathComponent.localizedStandardCompare(
        ($1.group as NSString).lastPathComponent) == .orderedAscending }
  }

  var body: some View {
    @Bindable var library = library
    List(selection: $selection) {
      ForEach(groups, id: \.group) { group in
        Section {
          ForEach(group.repositories) { repository in
            RepositoryRow(repository: repository, summary: library.summaries[repository.path])
              .tag(repository.path)
          }
        } header: {
          Text((group.group as NSString).lastPathComponent)
            .help((group.group as NSString).abbreviatingWithTildeInPath)
        }
      }
    }
    .contextMenu(forSelectionType: String.self) { paths in
      let selected = repositories.filter { paths.contains($0.path) }
      if selected.count == 1, let repository = selected.first {
        Button("Show in Finder") { RepositoryLibrary.reveal(repository.url) }
        Button("Open in Terminal") { RepositoryLibrary.openInTerminal(repository.url) }
        Divider()
      }
      if !selected.isEmpty {
        Button(selected.count == 1 ? "Remove from List" : "Remove \(selected.count) from List") {
          remove(selected)
        }
      }
    }
    .overlay {
      if repositories.isEmpty {
        ContentUnavailableView {
          Label("No Repositories", systemImage: "externaldrive.badge.plus")
        } description: {
          Text("Drop a folder here. Every Git repository inside it is added.")
        } actions: {
          Button("Add Folder…") { library.isImporterPresented = true }
        }
      } else if library.isImporting {
        ProgressView("Looking for repositories…")
          .padding()
          .background(.regularMaterial, in: .rect(cornerRadius: 8))
      }
    }
    .overlay {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.accentColor, lineWidth: 2)
          .padding(4)
          .allowsHitTesting(false)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      importFolders(urls)
      return true
    } isTargeted: { isDropTargeted = $0 }
    .fileImporter(
      isPresented: $library.isImporterPresented, allowedContentTypes: [.folder],
      allowsMultipleSelection: true
    ) { result in
      if case .success(let urls) = result { importFolders(urls) }
    }
    .alert(
      "Nothing to Add",
      isPresented: .init(
        get: { library.importMessage != nil }, set: { if !$0 { library.importMessage = nil } })
    ) {
      Button("OK") {}
    } message: {
      Text(library.importMessage ?? "")
    }
    .toolbar {
      ToolbarItem {
        Button("Add Folder…", systemImage: "plus") { library.isImporterPresented = true }
          .help("Add the Git repositories in a folder")
      }
    }
    .task {
      #if DEBUG
        // --add-folder <path> (repeatable) imports folders at launch, for testing.
        let arguments = ProcessInfo.processInfo.arguments
        let folders = arguments.indices.dropLast().filter { arguments[$0] == "--add-folder" }
          .map { URL(fileURLWithPath: arguments[$0 + 1]) }
        if !folders.isEmpty { importFolders(folders) }
      #endif
      await library.refreshSummaries(repositories.map(\.path))
    }
  }

  private func importFolders(_ urls: [URL]) {
    Task {
      let added = await library.importFolders(urls, into: context)
      if let first = added.first { selection = first }
    }
  }

  private func remove(_ selected: [SavedRepository]) {
    if let selection, selected.contains(where: { $0.path == selection }) { self.selection = nil }
    library.remove(selected, from: context)
  }
}

private struct RepositoryRow: View {
  let repository: SavedRepository
  let summary: RepositorySummary?

  var body: some View {
    HStack(spacing: 6) {
      VStack(alignment: .leading, spacing: 1) {
        Text(repository.name)
          .lineLimit(1)
        if !repository.exists {
          Label("Missing", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
        } else if let summary {
          HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
            Text(summary.branchLabel).lineLimit(1)
            if summary.ahead > 0 { Text("↑\(summary.ahead)") }
            if summary.behind > 0 { Text("↓\(summary.behind)") }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
      if let count = summary?.changeCount, count > 0 {
        Text("\(count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(.quaternary, in: .capsule)
      }
    }
    .help(repository.path)
  }
}
