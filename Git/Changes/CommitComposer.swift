import GitKit
import SwiftUI

/// Summary, description, Amend, and Commit / Commit & Push.
struct CommitComposer: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  @FocusState private var focusedField: Field?

  private enum Field { case summary, details }

  private var stagedCount: Int { session.status?.staged.count ?? 0 }
  private var canCommit: Bool {
    !state.summary.trimmingCharacters(in: .whitespaces).isEmpty
      && (stagedCount > 0 || state.amend) && !session.isBusy
      && session.status?.conflicted.isEmpty != false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Summary", text: $state.summary)
        .textFieldStyle(.roundedBorder)
        .focused($focusedField, equals: .summary)
        .onSubmit { focusedField = .details }
      TextEditor(text: $state.details)
        .font(.body)
        .focused($focusedField, equals: .details)
        .frame(minHeight: 44, maxHeight: 90)
        .scrollContentBackground(.hidden)
        .padding(4)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
        .overlay {
          RoundedRectangle(cornerRadius: 6).strokeBorder(.separator)
        }
        .overlay(alignment: .topLeading) {
          if state.details.isEmpty {
            Text("Description")
              .foregroundStyle(.placeholder)
              .padding(.horizontal, 9)
              .padding(.vertical, 4)
              .allowsHitTesting(false)
          }
        }
      HStack {
        Toggle("Amend", isOn: $state.amend)
          .toggleStyle(.checkbox)
          .disabled(session.status?.isUnborn ?? true)
          .help("Replace the last commit")
          .onChange(of: state.amend) { _, amend in
            if amend { Task { await prefillAmendMessage() } }
          }
        Spacer()
        Button("Commit & Push") { Task { await commit(push: true) } }
          .disabled(!canCommit)
        Button(state.amend ? "Amend" : "Commit") { Task { await commit(push: false) } }
          .keyboardShortcut(.return, modifiers: .command)
          .help(commitHelp)
          .buttonStyle(.borderedProminent)
          .disabled(!canCommit)
      }
    }
    .padding(10)
  }

  private var commitHelp: String {
    if state.amend { return "Replace the last commit (⌘↩)" }
    let files = stagedCount == 1 ? "1 staged file" : "\(stagedCount) staged files"
    let branch = session.status?.branch.map { " to \($0)" } ?? ""
    return "Commit \(files)\(branch) (⌘↩)"
  }

  private func prefillAmendMessage() async {
    guard state.summary.isEmpty && state.details.isEmpty,
      let message = try? await session.repository.lastCommitMessage()
    else { return }
    let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    state.summary = parts.first.map(String.init) ?? ""
    state.details =
      parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
  }

  private func commit(push: Bool) async {
    guard canCommit else { return }
    let summary = state.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    let details = state.details.trimmingCharacters(in: .whitespacesAndNewlines)
    let message = details.isEmpty ? summary : "\(summary)\n\n\(details)"
    guard await session.commit(message: message, amend: state.amend) else { return }
    state.summary = ""
    state.details = ""
    state.amend = false
    if push { await session.push(force: false) }
  }
}
