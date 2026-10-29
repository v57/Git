import ComponentKit
import GitKit
import GitUI
import SwiftUI

/// Stashes: each stash with Apply, Pop and Drop.
struct StashesScreen: View {
  let session: RepositorySession
  @State private var pendingDrop: Stash?

  var body: some View {
    Group {
      if session.stashes.isEmpty {
        EmptyState(
          systemImage: "archivebox", title: "No Stashes",
          message: "Stash puts uncommitted changes aside so you can switch branches.")
      } else {
        ScrollView {
          // Built as they near the screen, so a long list of stashes opens at once.
          KitLazyStack(spacing: KitMetrics.gutter) {
            ForEach(session.stashes) { stash in
              row(stash)
            }
          }
          .padding(KitMetrics.gutter)
          .frame(maxWidth: 760)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .kitPane(.secondary)
    .kitConfirmation(
      "Drop this stash?",
      isPresented: .init(get: { pendingDrop != nil }, set: { if !$0 { pendingDrop = nil } }),
      message: pendingDrop?.message, systemImage: "trash", confirm: "Drop"
    ) {
      if let stash = pendingDrop { Task { await session.dropStash(stash) } }
    }
  }

  private func row(_ stash: Stash) -> some View {
    RichHeader(stash.message, meta: [stash.reference, stash.date.historyFormatted], systemImage: "archivebox", hue: .indigo) {
      HStack(spacing: 6) {
        Button("Apply") { Task { await session.applyStash(stash) } }
        Button("Pop") { Task { await session.popStash(stash) } }
        Button("Drop…", role: .destructive) { pendingDrop = stash }
      }
      .buttonStyle(.kit)
      .controlSize(.small)
    }
    .disabled(session.isBusy)
    .padding(KitMetrics.cardPadding)
    .kitSurface(.card)
  }
}
