import Foundation

/// A fetch refspec such as `+refs/heads/*:refs/remotes/origin/*`.
struct Refspec {
  var source: String
  var destination: String
  var force: Bool

  init?(_ text: String) {
    var text = Substring(text)
    force = text.hasPrefix("+")
    if force { text = text.dropFirst() }
    let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty else { return nil }
    source = String(parts[0])
    destination = String(parts[1])
  }

  static func defaultFetch(remote: String) -> String { "+refs/heads/*:refs/remotes/\(remote)/*" }

  /// Maps a remote ref to its local name, or `nil` when the refspec doesn't cover it.
  func map(_ ref: String) -> String? { Self.translate(ref, from: source, to: destination) }

  /// Maps a local ref back to the remote one.
  func reverseMap(_ ref: String) -> String? { Self.translate(ref, from: destination, to: source) }

  private static func translate(_ ref: String, from pattern: String, to target: String) -> String? {
    guard let star = pattern.firstIndex(of: "*") else { return ref == pattern ? target : nil }
    let prefix = pattern[..<star]
    let suffix = pattern[pattern.index(after: star)...]
    guard ref.hasPrefix(prefix), ref.hasSuffix(suffix), ref.count >= prefix.count + suffix.count else { return nil }
    let middle = ref.dropFirst(prefix.count).dropLast(suffix.count)
    return target.replacingOccurrences(of: "*", with: middle)
  }
}

/// A branch's configured upstream.
struct Upstream {
  var remote: String
  /// The branch on the remote, e.g. `refs/heads/main`.
  var mergeRef: String
  /// Where its last fetched state lives, e.g. `refs/remotes/origin/main`.
  var trackingRef: String

  /// `origin/main`, as `git status` shows it.
  var shortName: String { GitEngine.shortName(trackingRef) }
}

extension GitContext {
  func fetchRefspecs(_ remote: String) -> [Refspec] {
    let configured = config.values("remote.\(remote).fetch").compactMap(Refspec.init)
    return configured.isEmpty ? [Refspec(Refspec.defaultFetch(remote: remote))!] : configured
  }

  /// `branch.<name>.remote` and `.merge`, mapped to the remote-tracking ref.
  func upstream(of branch: String) -> Upstream? {
    guard let remote = config.value("branch.\(branch).remote"), let merge = config.value("branch.\(branch).merge")
    else { return nil }
    if remote == "." { return Upstream(remote: remote, mergeRef: merge, trackingRef: merge) }
    for refspec in fetchRefspecs(remote) {
      if let tracking = refspec.map(merge) { return Upstream(remote: remote, mergeRef: merge, trackingRef: tracking) }
    }
    return nil
  }

  /// The remote to fetch from or push to for the current branch: its upstream's, else `origin`, else the only one.
  func defaultRemote() throws -> String {
    if let branch = try head().branchName, let remote = config.value("branch.\(branch).remote"), remote != "." {
      return remote
    }
    let remotes = config.subsections(of: "remote")
    if remotes.contains("origin") { return "origin" }
    if remotes.count == 1 { return remotes[0] }
    if remotes.isEmpty { throw GitEngineError.refused("This repository has no remote.") }
    throw GitEngineError.refused("Several remotes and none is the default. Set an upstream for the branch first.")
  }
}
