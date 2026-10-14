import GitKit
import SwiftUI

/// The commit form: summary with a character count, description, Amend, then Commit & Push and
/// "Commit N Files to branch".
struct CommitComposer: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  @FocusState private var focusedField: Field?

  private enum Field { case summary, details }

  private var stagedCount: Int { session.status?.staged.count ?? 0 }
  private var suggestedSummary: String? {
    guard let staged = session.status?.staged, staged.count == 1 else { return nil }
    return "Updated \(staged[0].fileName)"
  }
  private var commitSummary: String {
    let summary = state.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    return summary.isEmpty ? suggestedSummary ?? "" : summary
  }
  private var canCommit: Bool {
    !commitSummary.isEmpty
      && (stagedCount > 0 || state.amend) && !session.isBusy
      && session.status?.conflicted.isEmpty != false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          TextField(suggestedSummary ?? "Summary (required)", text: $state.summary)
            .textFieldStyle(.plain)
            .fontWeight(.semibold)
            .focused($focusedField, equals: .summary)
            .onSubmit { focusedField = .details }
            .onKeyPress(.tab) {
              guard state.summary.isEmpty, let suggestedSummary else { return .ignored }
              state.summary = suggestedSummary
              return .handled
            }
          if !state.summary.isEmpty {
            // Logs and tools cut summaries longer than about 50 characters.
            Text("\(state.summary.count)/50")
              .font(.system(size: 11).monospacedDigit())
              .foregroundStyle(state.summary.count > 50 ? Color.orange : .secondary)
              .contentTransition(.numericText(value: Double(state.summary.count)))
              .animation(.app, value: state.summary.count)
              .transition(.opacity)
              .help("Keep the summary to 50 characters so it isn't cut off in logs")
          }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .animation(.app, value: state.summary.isEmpty)
        Divider().padding(.horizontal, 12)
        TextEditor(text: $state.details)
          .font(.body)
          .focused($focusedField, equals: .details)
          .scrollContentBackground(.hidden)
          .padding(.horizontal, 7)
          .padding(.vertical, 8)
          .frame(height: 88)
          .overlay(alignment: .topLeading) {
            if state.details.isEmpty {
              Text("Description — why this change?")
                .foregroundStyle(.placeholder)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .allowsHitTesting(false)
            }
          }
      }
      .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
      Toggle("Amend last commit", isOn: $state.amend)
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .disabled(session.status?.isUnborn ?? true)
        .help("Replace the last commit with the staged changes and this message")
        .onChange(of: state.amend) { _, amend in
          if amend { Task { await prefillAmendMessage() } }
        }
      HStack(spacing: 8) {
        Button("Commit & Push") { Task { await commit(push: true) } }
          .buttonStyle(.design(size: .large))
          .keyboardShortcut(.return, modifiers: [.command, .shift])
          .disabled(!canCommit || session.remotes.isEmpty)
        Button {
          Task { await commit(push: false) }
        } label: {
          HStack(spacing: 8) {
            Text(commitTitle)
              .lineLimit(1)
              .truncationMode(.middle)
              .contentTransition(.numericText(value: Double(stagedCount)))
              .animation(.app, value: commitTitle)
            Text("⌘↩")
              .font(.system(size: 11))
              .opacity(0.85)
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.design(.primary, size: .large))
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canCommit)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 14)
    .padding(.bottom, 16)
    .background(Color.primary.opacity(0.015))
  }

  private var commitTitle: String {
    let branch = session.status?.branch ?? "HEAD"
    if state.amend { return "Amend Last Commit" }
    if stagedCount == 0 { return "Commit to \(branch)" }
    let files = stagedCount == 1 ? "1 File" : "\(stagedCount) Files"
    return "Commit \(files) to \(branch)"
  }

  private func prefillAmendMessage() async {
    guard state.summary.isEmpty && state.details.isEmpty,
      let message = try? await session.repository.lastCommitMessage()
    else { return }
    let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    state.summary = parts.first.map(String.init) ?? ""
    state.details = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
  }

  private func commit(push: Bool) async {
    guard canCommit else { return }
    let summary = commitSummary
    let details = state.details.trimmingCharacters(in: .whitespacesAndNewlines)
    let message = details.isEmpty ? summary : "\(summary)\n\n\(details)"
    let branch = session.status?.branch ?? "HEAD"
    guard await session.commit(message: message, amend: state.amend) else { return }
    state.summary = ""
    state.details = ""
    state.amend = false
    if push {
      if await session.push(force: false) {
        state.lastCommit = "Committed and pushed “\(summary)” to \(session.status?.upstream ?? branch)"
      } else {
        state.lastCommit = "Committed “\(summary)” to \(branch)"
      }
    } else {
      state.lastCommit = "Committed “\(summary)” to \(branch)"
    }
  }
}
