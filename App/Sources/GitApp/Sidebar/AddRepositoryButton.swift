import ComponentKit
import SwiftUI

/// The Repositories card's +: a menu to add the repositories in a folder (one without any asks to start one there),
/// clone one, or create a new one. The window runs each (`RepositoryLibrary`'s requests), as the File menu's items do.
struct AddRepositoryButton: View {
  @Environment(RepositoryLibrary.self) private var library
  @State private var showsMenu = false

  var body: some View {
    Button("Add Repository", systemImage: "plus") { showsMenu = true }
      .kitMenu(isPresented: $showsMenu) {
        Button("From Directory…", systemImage: "folder") { library.isImporterPresented = true }
          .kitMenuHint("⇧⌘O")
        Button("Clone…", systemImage: "arrow.down") { library.isClonePresented = true }
          .kitMenuHint("⇧⌘C")
        Button("Create New…", systemImage: "plus.square") { library.isCreateRequested = true }
          .kitMenuHint("⌥⌘N")
      }
      .kitHelp("Add Repository", meta: "From a folder, a clone or a new one", systemImage: "plus")
  }
}
