import ComponentKit
import SwiftUI

/// The Code app's bundle identifier: it opens a file with its repository as the project.
private let codeBundleID = "dev.v57.code"

/// A repository file's open items, for a row's context menu (Changes, a commit's files): Open, Open in each v57 app
/// that opens files of its type, Show in Finder and Copy Path. A file that isn't in the working tree any more (deleted,
/// or renamed since) has Copy Path alone.
///
/// ```swift
/// .kitContextMenu { FileOpenItems(repository: session.repository.url, path: file.path) }
/// ```
struct FileOpenItems: View {
  let repository: URL
  let path: String

  var body: some View {
    let url = repository.appendingPathComponent(path)
    if FileManager.default.fileExists(atPath: url.path) {
      Button("Open", systemImage: "arrow.up.right.square") { KitDesktop.open(url) }
      ForEach(KitDesktop.apps(toOpen: url, prefix: "dev.v57.")) { app in
        Button {
          // The repository first, so Code opens it as the project rather than the file's folder.
          let urls = app.bundleIdentifier == codeBundleID ? [repository, url] : [url]
          KitDesktop.open(urls, withApp: app.bundleIdentifier)
        } label: {
          Label {
            Text("Open in \(app.name)")
          } icon: {
            if let icon = KitDesktop.icon(forFile: app.url.path) {
              icon.resizable().frame(width: 16, height: 16)
            }
          }
        }
      }
      Button("Show in \(KitDesktop.fileManagerName)", systemImage: "folder") { RepositoryLibrary.reveal(url) }
    }
    Button("Copy Path", systemImage: "doc.on.doc") { KitPasteboard.copy(path) }
  }
}
