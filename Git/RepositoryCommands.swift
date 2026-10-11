import GitKit
import SwiftUI

extension FocusedValues {
  @Entry var repositorySession: RepositorySession?
}

struct RepositoryCommands: Commands {
  let library: RepositoryLibrary
  @FocusedValue(\.repositorySession) private var session

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Add Folder…") { library.isImporterPresented = true }
        .keyboardShortcut("o", modifiers: [.command, .shift])
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
      Button("Push") { run { await $0.push() } }
        .keyboardShortcut("p")
        .disabled(session?.status?.branch == nil || session?.remotes.isEmpty != false)
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
