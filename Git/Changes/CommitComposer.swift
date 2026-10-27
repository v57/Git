import ComponentKit
import GitKit
import SwiftUI

/// The commit form: summary with a character count, description, Amend, then Commit & Push and
/// "Commit N Files to branch".
struct CommitComposer: View {
  let session: RepositorySession
  @Bindable var state: RepositoryViewState
  @FocusState private var focusedField: Field?
  @Environment(\.showToast) private var showToast

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
              .foregroundStyle(state.summary.count > 50 ? AnyShapeStyle(Hue.orange.text) : AnyShapeStyle(.kitSecondary))
              .contentTransition(.numericText(value: Double(state.summary.count)))
              .animation(.kit, value: state.summary.count)
              .transition(.opacity)
              .help("Keep the summary to 50 characters so it isn't cut off in logs")
          }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .animation(.kit, value: state.summary.isEmpty)
        Rectangle().fill(.kitSeparator).frame(height: 1).padding(.horizontal, 12)
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
      .kitSurface(.card)
      Toggle("Amend last commit", isOn: $state.amend)
        .toggleStyle(.kitCheckbox)
        .disabled(session.status?.isUnborn ?? true)
        .help("Replace the last commit with the staged changes and this message")
        .onChange(of: state.amend) { _, amend in
          if amend { Task { await prefillAmendMessage() } }
        }
      HStack(spacing: KitMetrics.gutter) {
        Button("Commit & Push") { Task { await commit(push: true) } }
          .buttonStyle(.kit)
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
              .animation(.kit, value: commitTitle)
            Text(Keycaps.label("⌘↩"))
              .font(.system(size: 11))
              .opacity(0.75)
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canCommit)
      }
      .controlSize(.large)
    }
    .padding(KitMetrics.gutter)
  }

  private var commitTitle: String {
    if state.amend { return "Amend Last Commit" }
    if stagedCount == 0 { return "Commit" }
    return stagedCount == 1 ? "Commit 1 File" : "Commit \(stagedCount) Files"
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
    if push, await session.push(force: false) {
      showToast(Toast(
        "Committed and pushed “\(summary)” to \(session.status?.upstream ?? branch)", systemImage: "checkmark",
        duration: .seconds(20)))
    } else {
      showCommitToast("Committed “\(summary)” to \(branch)")
    }
  }

  /// "Committed “…” to main" with Undo, and Push (Publish… without a remote).
  private func showCommitToast(_ message: String) {
    let session = session
    let state = state
    let undo: @MainActor () -> Void = {
      Task {
        guard let undone = await session.undoLastCommit() else { return }
        if state.summary.isEmpty && state.details.isEmpty {
          let parts = undone.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
          state.summary = parts.first.map(String.init) ?? ""
          state.details = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }
      }
    }
    if session.remotes.isEmpty {
      showToast(Toast(message, systemImage: "checkmark", duration: .seconds(20), action: "Publish…", undo: undo) {
        state.isPublishPresented = true
      })
    } else {
      let ahead = session.status?.ahead ?? 0
      showToast(Toast(
        message, systemImage: "checkmark", duration: .seconds(20), action: ahead > 0 ? "Push \(ahead)" : "Push",
        undo: undo
      ) {
        Task {
          guard await session.push() else { return }
          showToast(Toast("Pushed to \(session.status?.upstream ?? "the remote")", systemImage: "checkmark"))
        }
      })
    }
  }
}
