import GitKit
import SwiftUI

extension FocusedValues {
  @Entry var repositorySession: RepositorySession?
  @Entry var repositoryViewState: RepositoryViewState?
}

struct RepositoryCommands: Commands {
  let library: RepositoryLibrary
  @FocusedValue(\.repositorySession) private var session
  @FocusedValue(\.repositoryViewState) private var state

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Clone Repository…") { library.isClonePresented = true }
        .keyboardShortcut("c", modifiers: [.command, .shift])
      Button("New Repository…") { library.isCreateRequested = true }
        .keyboardShortcut("n", modifiers: [.command, .option])
      Button("Open Repository…") { library.isImporterPresented = true }
        .keyboardShortcut("o", modifiers: .command)
      Button("Add Folder…") { library.isImporterPresented = true }
        .keyboardShortcut("o", modifiers: [.command, .shift])
    }
    CommandGroup(after: .toolbar) {
      HideWhitespaceToggle()
    }
    CommandGroup(before: .sidebar) {
      ForEach(RepositoryMode.allCases) { mode in
        Button(mode.title) { state?.mode = mode }
          .keyboardShortcut(mode.shortcut, modifiers: .command)
          .disabled(state == nil)
      }
      Divider()
    }
    CommandMenu("Repository") {
      Button("Refresh") { run { await $0.refresh() } }
        .keyboardShortcut("r")
      Divider()
      Button("Fetch") { run { await $0.fetch() } }
        .keyboardShortcut("f", modifiers: [.command, .shift])
      Button("Pull") { run { await $0.pull() } }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(session?.status?.upstream == nil)
      if session?.remotes.isEmpty == true {
        Button("Publish to GitHub…") { state?.isPublishPresented = true }
          .keyboardShortcut("p")
          .disabled(session?.status?.branch == nil || session?.headCommit == nil || session?.isBusy == true)
      } else {
        Button("Push") { run { await $0.push() } }
          .keyboardShortcut("p")
          .disabled(session?.status?.branch == nil)
      }
      Divider()
      Button("Stage All") { run { await $0.stageAll() } }
        .keyboardShortcut("a", modifiers: [.command, .shift])
      Button("Unstage All") { run { await $0.unstageAll() } }
      Divider()
      Button("Show in Finder") {
        if let session { RepositoryLibrary.reveal(session.repository.url) }
      }
      Button("Open in Terminal") {
        if let session { RepositoryLibrary.openInTerminal(session.repository.url) }
      }
    }
  }

  private func run(_ action: @escaping (RepositorySession) async -> Void) {
    guard let session, !session.isBusy else { return }
    Task { await action(session) }
  }
}

/// View › Hide Whitespace Changes, for every diff.
private struct HideWhitespaceToggle: View {
  @AppStorage(DiffOptions.hideWhitespaceKey) private var hideWhitespace = false

  var body: some View {
    Toggle("Hide Whitespace Changes", isOn: $hideWhitespace)
  }
}
