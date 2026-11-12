import ComponentKit
import GitKit
import SwiftUI
import VaultKit

/// Remove All Projects: what leaves every v57 app on this Mac, before it does. The projects are grouped as the
/// sidebar groups them, each with its icon, folder and state: the repositories with what they hold that isn't pushed,
/// and the folders Git doesn't list (notes, a website's research) marked so. Their folders stay on disk.
struct RemoveProjectsSheet: View {
  let repositories: [SavedRepository]
  let remove: () -> Void
  @Environment(RepositoryLibrary.self) private var library
  @Environment(\.kitDismiss) private var dismiss

  /// A project that goes: a repository in the list, or a vault project Git doesn't list.
  struct Item: Identifiable {
    let path: String
    let name: String
    let icon: Data?
    let summary: RepositorySummary?
    let isListed: Bool
    var id: String { path }
  }

  struct Section: Identifiable {
    let title: String
    /// The group's folder on this Mac, which its rows' places are said from.
    var folder: String?
    let items: [Item]
    var id: String { title }
  }

  var body: some View {
    let sections = sections
    let items = sections.flatMap(\.items)
    KitSheet(
      title: "Remove All \(items.count) Projects?", meta: "\(meta(items))",
      systemImage: "trash", hue: .red, width: 520
    ) {
      ForEach(sections) { section in
        FormCard(section.title) {
          ForEach(section.items) { item in row(item, in: section.folder) }
        }
      }
    } footer: {
      Spacer()
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(items.count == 1 ? "Remove Project" : "Remove \(items.count) Projects", role: .destructive) {
        dismiss()
        remove()
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
    }
  }

  private func row(_ item: Item, in group: String?) -> some View {
    let help = [place(of: item.path, in: group), item.summary?.branch].compactMap { $0 }.joined(separator: " · ")
    return FormRow(item.name, help: help, systemImage: item.isListed ? "arrow.triangle.branch" : "folder") {
      if let summary = item.summary {
        StatusMarks(summary: summary)
      } else if !item.isListed {
        Chip("Not in Git", style: .quiet).controlSize(.small)
      }
    }
    .tile {
      Avatar(name: item.name, imageData: item.icon, kind: .thing, size: 24)
    }
  }

  /// Where a project is: "in Agentus" inside its group's folder (nothing right in it), else its folder from home.
  private func place(of path: String, in group: String?) -> String? {
    let parent = (path as NSString).deletingLastPathComponent
    if let group, parent == group { return nil }
    if let group, parent.hasPrefix(group + "/") { return "in " + parent.dropFirst(group.count + 1) }
    return (parent as NSString).abbreviatingWithTildeInPath
  }

  /// How many go, and what their folders keep that isn't pushed.
  private func meta(_ items: [Item]) -> String {
    let summaries = items.compactMap(\.summary)
    let changed = summaries.count { $0.changeCount > 0 }
    let ahead = summaries.reduce(0) { $0 + $1.ahead }
    var unsaved: [String] = []
    if changed > 0 {
      unsaved.append(String(localized: "\(changed) have changes"))
    }
    if ahead > 0 {
      unsaved.append(
        String(localized: "\(ahead) commits aren't pushed"))
    }
    let left = String(
      localized: "They leave Code, Dev, Markdown and the other v57 apps on this Mac. Their folders stay on disk.")
    guard !unsaved.isEmpty else { return left }
    let kept = unsaved.joined(separator: String(localized: " and ")).capitalizedFirst
    return left + " " + String(localized: "\(kept): they stay there.")
  }

  /// The projects by the top-level group they are in, in the sidebar's order, then those in none.
  private var sections: [Section] {
    let vault = library.vault
    let device = vault.deviceID
    let tree = vault.projectTree
    let listed = Dictionary(repositories.map { ($0.path, $0) }) { first, _ in first }
    var byGroup: [String?: [Item]] = [:]
    var seen: Set<String> = []
    for project in vault.localProjects {
      guard let path = project.paths[device], seen.insert(path).inserted else { continue }
      let repository = listed[path]
      let item = Item(
        path: path, name: repository?.name ?? project.name, icon: project.icon,
        summary: repository.flatMap { library.summaries[$0.path] }, isListed: repository != nil)
      byGroup[tree.ancestors(of: project.id).first?.id, default: []].append(item)
    }
    // Repositories the vault doesn't have (not published yet).
    for repository in repositories where seen.insert(repository.path).inserted {
      byGroup[nil, default: []].append(
        Item(
          path: repository.path, name: repository.name, icon: nil, summary: library.summaries[repository.path],
          isListed: true))
    }
    let byName = { (items: [Item]) in
      items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var sections: [Section] = tree.roots.compactMap { node in
      guard let group = node.group, let items = byGroup[group.id] else { return nil }
      return Section(title: group.name, folder: group.paths[device], items: byName(items))
    }
    if let loose = byGroup[nil] {
      sections.append(Section(title: sections.isEmpty ? "Projects" : "Not in a Group", items: byName(loose)))
    }
    return sections
  }
}

extension String {
  /// "has changes" → "Has changes".
  fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
