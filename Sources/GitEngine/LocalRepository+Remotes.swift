import Foundation
import GitKit

extension LocalRepository {
  /// The remotes in `.git/config` order.
  public func remotes() async throws -> [String] {
    try context().remotes
  }

  /// The URL `remote` fetches from.
  public func remoteURL(_ remote: String) async throws -> String {
    try context().fetchURL(remote)
  }

  /// Adds a remote that fetches every branch into `refs/remotes/<name>/`.
  public func addRemote(_ name: String, url: String) async throws {
    let context = try context()
    guard BranchName.isValid(name), !name.contains("/") else {
      throw GitEngineError.refused("“\(name)” isn't a valid remote name.")
    }
    guard context.config.value("remote.\(name).url") == nil else {
      throw GitEngineError.refused("A remote named \(name) already exists.")
    }
    try context.updateConfig { config in
      try config.set("remote.\(name).url", url)
      try config.set("remote.\(name).fetch", Refspec.defaultFetch(remote: name))
    }
  }

  /// Fetches every remote, as `git fetch --all --prune`: its branches into `refs/remotes/<remote>/` (removing ones the
  /// server no longer has) and tags that point into what was fetched. One that fails doesn't stop the others; the
  /// first failure is thrown at the end.
  @concurrent public func fetch(progress: (@Sendable (String) -> Void)? = nil) async throws {
    try await Fetcher(context: try context()).fetch(remotes: nil, progress: progress)
  }

  /// Fetches, then fast-forwards the current branch to its upstream, updating the working tree. Refuses when the
  /// branches have diverged.
  @concurrent public func pull(progress: (@Sendable (String) -> Void)? = nil) async throws {
    let context = try context()
    guard let branch = try context.head().branchName else {
      throw GitEngineError.refused("HEAD is detached. Switch to a branch before pulling.")
    }
    guard let upstream = context.upstream(of: branch) else {
      throw GitEngineError.refused("\(branch) doesn't track a remote branch. Push it first to set one.")
    }
    if upstream.remote != "." {
      _ = try await Fetcher(context: context).fetch(upstream.remote, prune: context.prunesOnPull(upstream.remote), progress: progress)
    }
    guard let target = context.refs.resolve(upstream.trackingRef) else {
      throw GitEngineError.notFound("\(upstream.shortName) doesn't exist on the remote.")
    }
    let current = try context.headCommit()
    if current == target { return }
    if let current {
      if try RevWalk.isAncestor(context.objects, target, of: current) { return }
      guard try RevWalk.isAncestor(context.objects, current, of: target) else {
        throw GitEngineError.refused(
          "\(branch) and \(upstream.shortName) have both changed, so they can't be fast-forwarded. Merging isn't "
            + "available on this device.")
      }
    }
    var index = try context.readIndex()
    try Checkout(context: context).move(
      from: current.map { try context.objects.commit($0).tree }, to: context.objects.commit(target).tree,
      index: &index)
    try context.writeIndex(index)
    try context.refs.update(
      "refs/heads/\(branch)", to: target, expected: current ?? .zero, message: "pull: Fast-forward")
    progress?("Fast-forwarded \(branch) to \(upstream.shortName).")
  }

  /// Pushes the current branch to its push remote (as `git push`, `Repository.pushRemote`): to its upstream, or to a
  /// branch of the same name, which then becomes its upstream. Refuses when the remote has commits this branch
  /// doesn't; with `force`, only when it has commits you haven't fetched (`--force-with-lease`).
  @concurrent public func push(force: Bool = false, progress: (@Sendable (String) -> Void)? = nil) async throws {
    try await Pusher(context: try context()).push(force: force, progress: progress)
  }

  /// Deletes `branch` on `remote`, as long as it's still at `expected`: what was last fetched
  /// (`--force-with-lease=<ref>:<expected> --delete`). Its remote-tracking branch goes too.
  @concurrent public func deleteRemoteBranch(
    _ branch: String, on remote: String, expected: String, progress: (@Sendable (String) -> Void)? = nil
  ) async throws {
    guard let expected = ObjectID(hex: expected) else {
      throw GitEngineError.refused("“\(expected)” isn't a commit.")
    }
    try await Pusher(context: try context()).delete(branch, on: remote, expected: expected, progress: progress)
  }

  /// Clones `remote` (HTTPS, or SSH through `GitSSH`) into `url`, which must not exist or be empty: fetches every branch, checks out the
  /// remote's default branch and sets `origin` and the branch's upstream as `git clone` does.
  @concurrent public static func clone(
    from remote: String, to url: URL, progress: (@Sendable (String) -> Void)? = nil
  ) async throws -> LocalRepository {
    try await clone(from: remote, to: url, settings: nil, checksOut: true, progress: progress)
  }

  /// `checksOut` false leaves the working tree to `git checkout` where there's git to run it (filters, line endings).
  @concurrent static func clone(
    from remote: String, to url: URL, settings: [GitSetting]?, checksOut: Bool,
    progress: (@Sendable (String) -> Void)?
  ) async throws -> LocalRepository {
    let url = url.standardizedFileURL
    let fileManager = FileManager.default
    let existed = fileManager.fileExists(atPath: url.path)
    if existed, !((try? fileManager.contentsOfDirectory(atPath: url.path))?.isEmpty ?? false) {
      throw GitEngineError.refused("\(url.lastPathComponent) already exists and isn't empty.")
    }
    do {
      progress?("Cloning into '\(url.lastPathComponent)'...")
      let repository = try initialize(at: url)
      let context = try repository.context(settings: settings)
      try context.updateConfig { config in
        try config.set("remote.origin.url", remote)
        try config.set("remote.origin.fetch", Refspec.defaultFetch(remote: "origin"))
      }
      let refs = try await Fetcher(context: context).fetch("origin", progress: progress)
      let heads = refs.filter { $0.name.hasPrefix("refs/heads/") }
      let headRef = refs.first { $0.name == "HEAD" }
      // The remote's HEAD, else a branch at the same commit, preferring main and master.
      let defaultBranch =
        headRef?.symrefTarget.flatMap { target in heads.first { $0.name == target } }
        ?? heads.filter { $0.id == headRef?.id }.sorted { rank($0.name) < rank($1.name) }.first
        ?? heads.sorted { rank($0.name) < rank($1.name) }.first
      if let defaultBranch {
        let name = shortName(defaultBranch.name)
        try context.refs.update(
          defaultBranch.name, to: defaultBranch.id, expected: .zero, message: "clone: from \(remote)")
        try context.updateConfig { config in
          try config.set("branch.\(name).remote", "origin")
          try config.set("branch.\(name).merge", defaultBranch.name)
        }
        try context.refs.setSymbolic("HEAD", to: defaultBranch.name)
        try context.refs.setSymbolic("refs/remotes/origin/HEAD", to: "refs/remotes/origin/\(name)")
        if checksOut {
          var index = GitIndex()
          try Checkout(context: context).move(
            from: nil, to: context.objects.commit(defaultBranch.id).tree, index: &index)
          try context.writeIndex(index)
        }
      } else if let target = headRef?.symrefTarget, target.hasPrefix("refs/heads/"), RefName.isValid(target) {
        try context.refs.setSymbolic("HEAD", to: target)
      }
      return repository
    } catch {
      if existed {
        for item in (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? [] {
          try? fileManager.removeItem(at: url.appendingPathComponent(item))
        }
      } else {
        try? fileManager.removeItem(at: url)
      }
      throw error
    }
  }

  private static func rank(_ ref: String) -> Int {
    ref == "refs/heads/main" ? 0 : ref == "refs/heads/master" ? 1 : 2
  }
}

/// Fetches remotes' branches and tags into the repository.
struct Fetcher {
  let context: GitContext

  /// Fetches `remotes` (every remote, leaving out `skipFetchAll`, with nil), the rest going on when one fails; the
  /// first failure is thrown at the end, one that git might do better preferred last so the caller sees a real answer
  /// first.
  func fetch(remotes names: [String]?, progress: (@Sendable (String) -> Void)?) async throws {
    let names =
      names ?? context.remotes.filter { !context.settings.bool("remote.\($0).skipFetchAll", default: false) }
    var failures: [any Error] = []
    var appends = false
    for name in names {
      do {
        _ = try await fetch(name, prune: true, appendsFetchHead: appends, progress: progress)
        appends = true
      } catch {
        failures.append(error)
      }
    }
    if let failure = failures.first(where: { !GitEngineNetwork.gitMightDoBetter($0) }) ?? failures.first { throw failure }
  }

  /// Fetches `remote` and returns the refs it advertised.
  func fetch(
    _ remote: String, prune: Bool = true, appendsFetchHead: Bool = false, progress: (@Sendable (String) -> Void)?
  ) async throws -> [RemoteRef] {
    let url = try context.fetchURL(remote)
    let uploadPack = try await UploadPack.connect(url)
    defer { uploadPack.transport.close() }
    if let format = uploadPack.unsupportedObjectFormat {
      throw GitEngineError.unsupported("\(remote) uses \(format) object IDs, which Git in the app doesn't read yet.")
    }
    let refspecs = context.fetchRefspecs(remote)
    let refs = try await uploadPack.listRefs(prefixes: refspecs.map { String($0.source.prefix { $0 != "*" }) })
    let store = context.objects

    // Remote branches mapped to local names.
    var updates: [(local: String, id: ObjectID, force: Bool)] = []
    for ref in refs where ref.name != "HEAD" {
      for refspec in refspecs {
        if let local = refspec.map(ref.name) {
          updates.append((local, ref.id, refspec.force))
          break
        }
      }
    }
    let tagOption = context.settings.value("remote.\(remote).tagOpt")
    let tags =
      tagOption == "--no-tags" ? [] : refs.filter { $0.name.hasPrefix("refs/tags/") && context.refs.resolve($0.name) == nil }
    var wants = Set(updates.map(\.id).filter { !store.contains($0) })
    // A new tag on a commit already here; with `--tags`, every one.
    for tag in tags where !store.contains(tag.id) && (tagOption == "--tags" || store.contains(tag.peeled ?? tag.id)) {
      wants.insert(tag.id)
    }

    if !wants.isEmpty {
      // Branch tips we have, so the server leaves out what they already reach.
      var haves: [ObjectID] = []
      var seen = Set<ObjectID>()
      for prefix in ["refs/heads/", "refs/remotes/"] {
        for (_, id) in context.refs.list(prefix) where store.contains(id) && seen.insert(id).inserted { haves.append(id) }
      }
      let indexer = try PackIndexer(
        packDirectory: store.directory.appendingPathComponent("pack"), progress: progress)
      try await uploadPack.fetch(
        wants: wants.sorted(), haves: Array(haves.prefix(256)), indexer: indexer, progress: progress)
      try indexer.finish(store: store)
      store.reloadPacks()
      for want in wants where !store.contains(want) {
        throw GitEngineError.network("The server didn't send \(want.hex).")
      }
    }

    for update in updates {
      let old = context.refs.resolve(update.local)
      guard old != update.id else { continue }
      var message = "fetch: storing head"
      if let old {
        let fastForward = (try? RevWalk.isAncestor(store, old, of: update.id)) ?? false
        if !fastForward && !update.force { continue }
        message = fastForward ? "fetch: fast-forward" : "fetch: forced-update"
      }
      try context.refs.update(update.local, to: update.id, message: message)
    }
    // Prune branches the server dropped.
    if prune {
      let fetched = Set(updates.map(\.local))
      for refspec in refspecs where refspec.destination.hasSuffix("/*") {
        let prefix = String(refspec.destination.dropLast())
        for (name, _) in context.refs.list(prefix) where !fetched.contains(name) && !context.refs.isSymbolic(name) {
          try context.refs.delete(name)
        }
      }
    }
    for tag in tags where store.contains(tag.id) {
      try context.refs.update(tag.name, to: tag.id, expected: .zero, message: "fetch: tag")
    }
    // The remote's default branch, the first time it's seen: git's `followRemoteHEAD`, which is `create` unless set.
    let followsHEAD = context.settings.value("remote.\(remote).followRemoteHEAD") ?? "create"
    let remoteHEAD = "refs/remotes/\(remote)/HEAD"
    if followsHEAD == "create", context.refs.resolve(remoteHEAD) == nil, !context.refs.isSymbolic(remoteHEAD),
      let target = refs.first(where: { $0.name == "HEAD" })?.symrefTarget,
      let local = refspecs.lazy.compactMap({ $0.map(target) }).first, local.hasPrefix("refs/remotes/\(remote)/"),
      context.refs.resolve(local) != nil
    {
      try context.refs.setSymbolic(remoteHEAD, to: local)
    }
    try writeFetchHead(remote: remote, url: url, refs: refs, tags: tags, appends: appendsFetchHead)
    return refs
  }

  /// `FETCH_HEAD`, as git leaves it: what `git merge FETCH_HEAD` merges first (the current branch's upstream, when this
  /// is its remote), then the rest as not-for-merge. Its date is when the repository last fetched.
  private func writeFetchHead(remote: String, url: String, refs: [RemoteRef], tags: [RemoteRef], appends: Bool) throws {
    let source = Self.anonymized(url)
    var merging: Set<String> = []
    if let branch = try? context.head().branchName, context.settings.value("branch.\(branch).remote") == remote {
      merging = Set(context.settings.values("branch.\(branch).merge"))
    }
    func line(_ ref: RemoteRef, _ forMerge: Bool) -> String {
      let kind = ref.name.hasPrefix("refs/tags/") ? "tag" : ref.name.hasPrefix("refs/heads/") ? "branch" : "ref"
      return "\(ref.id.hex)\t\(forMerge ? "" : "not-for-merge")\t\(kind) '\(shortName(ref.name))' of \(source)\n"
    }
    let wanted = refs.filter { ref in
      ref.name != "HEAD" && context.fetchRefspecs(remote).contains { $0.map(ref.name) != nil }
    }
    let lines =
      wanted.filter { merging.contains($0.name) }.map { line($0, true) }
      + wanted.filter { !merging.contains($0.name) }.map { line($0, false) }
      + tags.filter { context.objects.contains($0.id) }.map { line($0, false) }
    let file = context.gitDirectory.appendingPathComponent("FETCH_HEAD")
    var text = appends ? ((try? String(contentsOf: file, encoding: .utf8)) ?? "") : ""
    text += lines.joined()
    do {
      try Data(text.utf8).write(to: file)
    } catch {
      throw GitEngineError.file(error, file.path)
    }
  }

  /// An address as git writes it in `FETCH_HEAD` and merge messages: no login, no trailing `/` or `.git`.
  static func anonymized(_ url: String) -> String {
    var text = url
    if let scheme = text.range(of: "://") {
      let rest = text[scheme.upperBound...]
      let end = rest.firstIndex(of: "/") ?? rest.endIndex
      if let at = rest[..<end].lastIndex(of: "@") { text.removeSubrange(scheme.upperBound...at) }
    } else if let colon = text.firstIndex(of: ":"), let at = text[..<colon].lastIndex(of: "@") {
      text.removeSubrange(text.startIndex...at)
    }
    while text.hasSuffix("/") { text.removeLast() }
    if text.hasSuffix(".git") { text.removeLast(4) }
    return text
  }
}

extension GitContext {
  /// `git pull` prunes only when configured to.
  func prunesOnPull(_ remote: String) -> Bool {
    settings.bool("remote.\(remote).prune", default: settings.bool("fetch.prune", default: false))
  }
}
