import GitKit
import SwiftUI

/// Stashes: each stash with Apply, Pop and Drop.
struct StashesScreen: View {
  let session: RepositorySession
  @State private var pendingDrop: Stash?

  var body: some View {
    Group {
      if session.stashes.isEmpty {
        ContentUnavailableView {
          Label("No Stashes", systemImage: "archivebox")
        } description: {
          Text("Stash puts uncommitted changes aside so you can switch branches.")
        }
      } else {
        ScrollView {
          VStack(spacing: 8) {
            ForEach(session.stashes) { stash in
              row(stash)
            }
          }
          .padding(20)
          .frame(maxWidth: 760)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .confirmationDialog(
      "Drop this stash?",
      isPresented: .init(get: { pendingDrop != nil }, set: { if !$0 { pendingDrop = nil } }),
      titleVisibility: .visible
    ) {
      Button("Drop", role: .destructive) {
        if let stash = pendingDrop { Task { await session.dropStash(stash) } }
      }
    } message: {
      Text(pendingDrop?.message ?? "")
    }
  }

  private func row(_ stash: Stash) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "archivebox")
        .font(.system(size: 15))
        .foregroundStyle(Color.accentColor)
        .frame(width: 32, height: 32)
        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(stash.message)
          .fontWeight(.semibold)
          .lineLimit(1)
        Text("\(stash.reference) · \(stash.date.historyFormatted)")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      Spacer()
      Group {
        Button("Apply") { Task { await session.applyStash(stash) } }
        Button("Pop") { Task { await session.popStash(stash) } }
        Button("Drop…") { pendingDrop = stash }
      }
      .buttonStyle(.design(size: .small))
    }
    .disabled(session.isBusy)
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
  }
}
