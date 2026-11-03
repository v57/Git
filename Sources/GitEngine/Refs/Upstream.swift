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
    let configured = settings.values("remote.\(remote).fetch").compactMap(Refspec.init)
    return configured.isEmpty ? [Refspec(Refspec.defaultFetch(remote: remote))!] : configured
  }

  /// `branch.<name>.remote` and `.merge`, mapped to the remote-tracking ref.
  func upstream(of branch: String) -> Upstream? {
    guard let remote = settings.value("branch.\(branch).remote"), let merge = settings.value("branch.\(branch).merge")
    else { return nil }
    if remote == "." { return Upstream(remote: remote, mergeRef: merge, trackingRef: merge) }
    for refspec in fetchRefspecs(remote) {
      if let tracking = refspec.map(merge) { return Upstream(remote: remote, mergeRef: merge, trackingRef: tracking) }
    }
    return nil
  }

  /// The remote `git push` uses for `branch`: the branch's push remote, the default push remote, its upstream's, else
  /// `origin`, else the only one (as `Repository.pushRemote`).
  func pushRemote(for branch: String) throws -> String {
    for key in ["branch.\(branch).pushRemote", "remote.pushDefault", "branch.\(branch).remote"] {
      if let value = settings.value(key), !value.isEmpty { return value }
    }
    let remotes = self.remotes
    if remotes.contains("origin") { return "origin" }
    if remotes.count == 1 { return remotes[0] }
    if remotes.isEmpty { throw GitEngineError.refused("This repository has no remote to push to.") }
    throw GitEngineError.refused(
      "Several remotes and none is the default. Set one with git config remote.pushDefault <remote>.")
  }

  /// The remotes, in the order git read them.
  var remotes: [String] { settings.subsections(of: "remote").filter { settings.value("remote.\($0).url") != nil } }

  /// The address `remote` fetches from, with `url.<base>.insteadOf` applied.
  func fetchURL(_ remote: String) throws -> String {
    guard let url = settings.values("remote.\(remote).url").first else {
      throw GitEngineError.notFound("There's no remote named \(remote).")
    }
    return rewritten(url, "insteadof") ?? url
  }

  /// The addresses `remote` pushes to: every `pushurl`, else its `url` (`pushInsteadOf` first, then `insteadOf`).
  func pushURLs(_ remote: String) throws -> [String] {
    let pushURLs = settings.values("remote.\(remote).pushurl")
    if !pushURLs.isEmpty { return pushURLs.map { rewritten($0, "insteadof") ?? $0 } }
    let urls = settings.values("remote.\(remote).url")
    if urls.isEmpty { throw GitEngineError.notFound("There's no remote named \(remote).") }
    return urls.map { rewritten($0, "pushinsteadof") ?? rewritten($0, "insteadof") ?? $0 }
  }

  /// `url` with the longest prefix a `url.<base>.<key>` names replaced by its base.
  private func rewritten(_ url: String, _ key: String) -> String? {
    var best: (prefix: String, base: String)?
    for base in settings.subsections(of: "url") {
      for prefix in settings.values("url.\(base).\(key)") where url.hasPrefix(prefix) {
        if prefix.count > (best?.prefix.count ?? -1) { best = (prefix, base) }
      }
    }
    return best.map { $0.base + url.dropFirst($0.prefix.count) }
  }
}
