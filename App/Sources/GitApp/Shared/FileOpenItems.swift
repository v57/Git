import ComponentKit
import GitKit
import SwiftUI

/// The Code app's bundle identifier: it opens a file with its repository as the project.
let codeBundleID = "dev.v57.code"

/// A repository file's open items, for a row's context menu (Changes, a commit's files): the Open With row (its
/// usual app, each v57 app that opens files of its type, Finder), then Copy Path. A file that isn't in the working tree
/// any more (deleted, or renamed since), or that is on another device, has Copy Path alone. `inCommit`: the menu is a
/// commit's, so the sentences say the file opens as it is now.
///
/// ```swift
/// .kitContextMenu { FileOpenItems(repository: session.repository, path: file.path) }
/// ```
struct FileOpenItems: View {
  let repository: Repository
  let path: String
  var inCommit = false

  var body: some View {
    let url = repository.url.appendingPathComponent(path)
    if !repository.isRemote, FileManager.default.fileExists(atPath: url.path) {
      let name = url.lastPathComponent
      let now = inCommit ? " as it is now, not as in this commit" : ""
      let usual = KitDesktop.defaultApp(for: url)
      KitOpenWithRow(
        [.defaultApp(opening: url, preview: "Opens \(name) in \(usual?.name ?? "its usual app")\(now).")]
          + KitDesktop.apps(toOpen: url, prefix: "dev.v57.").filter { $0.bundleIdentifier != usual?.bundleIdentifier }
          .map { app in
            KitOpenApp(
              app.name, icon: KitDesktop.icon(forFile: app.url.path), preview: "Opens \(name) in \(app.name)\(now).",
              id: app.bundleIdentifier
            ) {
              // The repository first, so Code opens it as the project rather than the file's folder.
              let urls = app.bundleIdentifier == codeBundleID ? [repository.url, url] : [url]
              KitDesktop.open(urls, withApp: app.bundleIdentifier)
            }
          }
          + [.fileManager(revealing: [url], preview: "Shows \(name) in \(KitDesktop.fileManagerName).")])
      Divider()
    }
    Button("Copy Path", systemImage: "doc.on.doc") { KitPasteboard.copy(path) }
  }
}
