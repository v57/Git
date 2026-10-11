import Foundation

/// Finds the git repositories inside a folder (ported from Dev's sidebar import).
///
/// A repository is a directory with a `.git` entry (a directory, or a file for worktrees and
/// submodules). The walk never descends into a repository, so nested packages and submodules are
/// not listed separately. It skips hidden folders, symlinks, packages (`.app`, `.xcodeproj`) and
/// dependency/build folders, and stops `maxDepth` levels down.
public enum RepoDiscovery {
  public static let maxDepth = 6
  public static let ignoredNames: Set<String> = [
    "node_modules", "DerivedData", "build", "Build", "Pods", "Carthage", "vendor", "target", "dist",
    "__pycache__", "venv",
  ]

  /// The repositories at or under `root`, sorted by path. Empty when there are none.
  public static func scan(_ root: URL) -> [URL] {
    let root = root.standardizedFileURL
    if isRepository(root) { return [root] }
    var repos: [URL] = []
    walk(root, depth: 0, into: &repos)
    return repos.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  /// Scans off the calling actor.
  public static func scan(_ roots: [URL]) async -> [URL: [URL]] {
    await Task.detached(priority: .userInitiated) {
      var result: [URL: [URL]] = [:]
      for root in roots { result[root] = scan(root) }
      return result
    }.value
  }

  public static func isRepository(_ directory: URL) -> Bool {
    FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path)
  }

  private static func walk(_ directory: URL, depth: Int, into repos: inout [URL]) {
    guard depth < maxDepth else { return }
    for child in childDirectories(of: directory) {
      if isRepository(child) {
        repos.append(child)
      } else {
        walk(child, depth: depth + 1, into: &repos)
      }
    }
  }

  private static func childDirectories(of directory: URL) -> [URL] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
    guard
      let children = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    else { return [] }
    return children.compactMap { url in
      guard let values = try? url.resourceValues(forKeys: Set(keys)),
        values.isDirectory == true,
        values.isSymbolicLink != true,
        values.isPackage != true,
        !ignoredNames.contains(url.lastPathComponent)
      else { return nil }
      return url.standardizedFileURL
    }
  }
}
