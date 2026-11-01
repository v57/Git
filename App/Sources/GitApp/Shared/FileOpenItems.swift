import ComponentKit
import GitKit
import SwiftUI

/// The Code app's bundle identifier: it opens a file with its repository as the project.
private let codeBundleID = "dev.v57.code"

/// A repository file's open items, for a row's context menu (Changes, a commit's files): Open, Open in each v57 app
/// that opens files of its type, Show in Finder and Copy Path. A file that isn't in the working tree any more (deleted,
/// or renamed since), or that is on another device, has Copy Path alone.
///
/// ```swift
/// .kitContextMenu { FileOpenItems(repository: session.repository, path: file.path) }
/// ```
struct FileOpenItems: View {
  let repository: Repository
  let path: String

  var body: some View {
    let url = repository.url.appendingPathComponent(path)
    if !repository.isRemote, FileManager.default.fileExists(atPath: url.path) {
      Button("Open", systemImage: "arrow.up.right.square") { KitDesktop.open(url) }
      ForEach(KitDesktop.apps(toOpen: url, prefix: "dev.v57.")) { app in
        Button {
          // The repository first, so Code opens it as the project rather than the file's folder.
          let urls = app.bundleIdentifier == codeBundleID ? [repository.url, url] : [url]
          KitDesktop.open(urls, withApp: app.bundleIdentifier)
        } label: {
          AppLabel(title: "Open in \(app.name)", icon: KitDesktop.icon(forFile: app.url.path))
        }
      }
      ShowInFileManager([url])
    }
    Button("Copy Path", systemImage: "doc.on.doc") { KitPasteboard.copy(path) }
  }
}

/// Show in Finder, with Finder's own icon as the Open in items have their apps'.
struct ShowInFileManager: View {
  let urls: [URL]
  init(_ urls: [URL]) { self.urls = urls }

  var body: some View {
    Button {
      KitDesktop.reveal(urls)
    } label: {
      AppLabel(title: "Show in \(KitDesktop.fileManagerName)", icon: KitDesktop.fileManagerIcon)
    }
  }
}

/// An item with the app's own icon (a folder where there is none).
private struct AppLabel: View {
  let title: String
  let icon: Image?

  var body: some View {
    Label {
      Text(title)
    } icon: {
      if let icon {
        icon.resizable().frame(width: 16, height: 16)
      } else {
        Image(systemName: "folder")
      }
    }
  }
}
