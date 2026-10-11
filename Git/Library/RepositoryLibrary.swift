import AppKit
import GitKit
import SwiftData
import SwiftUI

/// What the window shows for a repository.
enum RepositoryMode: String, CaseIterable, Identifiable {
  case changes, history
  var id: Self { self }
  var title: String { self == .changes ? "Changes" : "History" }
}

/// Per-repository UI state that survives switching repositories: selections and the commit
/// message draft.
@Observable final class RepositoryViewState {
  var mode: RepositoryMode = .changes
  var selectedChanges: Set<FileChange.ID> = []
  var selectedCommit: Commit.ID?
  var selectedCommitFile: CommitFile.ID?
  var summary = ""
  var details = ""
  var amend = false
}

/// The app's repositories: one session and view state per repository, sidebar summaries, and
/// recursive folder import.
@MainActor @Observable final class RepositoryLibrary {
  private(set) var sessions: [String: RepositorySession] = [:]
  private(set) var viewStates: [String: RepositoryViewState] = [:]
  private(set) var summaries: [String: RepositorySummary] = [:]
  private(set) var isImporting = false
  var isImporterPresented = false
  /// Shown after an import that found nothing.
  var importMessage: String?

  private weak var activeSession: RepositorySession?

  func session(for path: String) -> RepositorySession {
    if let session = sessions[path] { return session }
    let session = RepositorySession(url: URL(fileURLWithPath: path, isDirectory: true))
    sessions[path] = session
    return session
  }

  func viewState(for path: String) -> RepositoryViewState {
    if let state = viewStates[path] { return state }
    let state = RepositoryViewState()
    viewStates[path] = state
    return state
  }

  /// Watches only the repository on screen.
  func activate(_ path: String?) async {
    let session = path.map(session(for:))
    if activeSession !== session {
      activeSession?.deactivate()
      activeSession = session
    }
    await session?.activate()
    if let session, let path { updateSummary(path, from: session) }
  }

  func updateSummary(_ path: String, from session: RepositorySession) {
    guard let status = session.status else { return }
    summaries[path] = RepositorySummary(status)
  }

  /// Reloads branch and change counts for the sidebar, a few repositories at a time.
  func refreshSummaries(_ paths: [String]) async {
    await withTaskGroup(of: (String, RepositorySummary?).self) { group in
      var pending = paths[...]
      func addNext() {
        guard let path = pending.popFirst() else { return }
        group.addTask {
          let summary = try? await Repository(url: URL(fileURLWithPath: path)).summary()
          return (path, summary)
        }
      }
      for _ in 0..<6 { addNext() }
      for await (path, summary) in group {
        if let summary { summaries[path] = summary } else { summaries[path] = nil }
        addNext()
      }
    }
  }

  /// Adds every repository found in the dropped or picked folders. Returns the added paths.
  @discardableResult
  func importFolders(_ urls: [URL], into context: ModelContext) async -> [String] {
    let folders = urls.filter {
      $0.isFileURL && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    guard !folders.isEmpty else { return [] }
    isImporting = true
    defer { isImporting = false }

    let found = await RepoDiscovery.scan(folders)
    let existing = Set(
      ((try? context.fetch(FetchDescriptor<SavedRepository>())) ?? []).map(\.path))
    var added: [String] = []
    for folder in folders {
      let repos = found[folder] ?? []
      for repo in repos where !existing.contains(repo.path) && !added.contains(repo.path) {
        // A repository dropped on its own is grouped under its parent folder.
        let group = repos == [folder.standardizedFileURL]
          ? folder.deletingLastPathComponent().path : folder.standardizedFileURL.path
        context.insert(SavedRepository(path: repo.path, group: group))
        added.append(repo.path)
      }
    }
    try? context.save()

    let foundCount = found.values.reduce(0) { $0 + $1.count }
    if foundCount == 0 {
      let names = folders.map(\.lastPathComponent).formatted()
      importMessage = "No Git repositories were found in \(names)."
    }
    await refreshSummaries(added)
    return added
  }

  func remove(_ repositories: [SavedRepository], from context: ModelContext) {
    for repository in repositories {
      sessions[repository.path]?.deactivate()
      sessions[repository.path] = nil
      viewStates[repository.path] = nil
      summaries[repository.path] = nil
      context.delete(repository)
    }
    try? context.save()
  }

  // MARK: Finder and Terminal

  static func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  static func openInTerminal(_ url: URL) {
    guard
      let terminal = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.Terminal")
    else { return }
    NSWorkspace.shared.open(
      [url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
  }
}
