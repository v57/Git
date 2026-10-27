import Foundation
import GitKit

extension LocalRepository {
  /// The remotes in `.git/config` order.
  public func remotes() async throws -> [String] {
    try context().config.subsections(of: "remote")
  }

  /// The URL `remote` fetches from.
  public func remoteURL(_ remote: String) async throws -> String {
    guard let url = try context().config.value("remote.\(remote).url") else {
      throw GitEngineError.notFound("There's no remote named \(remote).")
    }
    return url
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

  /// Fetches the current branch's remote (or `origin`): its branches into `refs/remotes/<remote>/` (removing ones the
  /// server no longer has) and tags that point into what was fetched.
  @concurrent public func fetch(progress: (@Sendable (String) -> Void)? = nil) async throws {
    let context = try context()
    _ = try await Fetcher(context: context).fetch(context.defaultRemote(), progress: progress)
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
      _ = try await Fetcher(context: context).fetch(upstream.remote, progress: progress)
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

  /// Pushes the current branch to its upstream, or to a branch of the same name on the default remote, which then
  /// becomes its upstream. Only fast-forwards: refuses when the remote has commits this branch doesn't.
  @concurrent public func push(progress: (@Sendable (String) -> Void)? = nil) async throws {
    let context = try context()
    guard let branch = try context.head().branchName else {
      throw GitEngineError.refused("HEAD is detached. Switch to a branch before pushing.")
    }
    guard let local = context.refs.resolve("refs/heads/\(branch)") else {
      throw GitEngineError.refused("There's nothing to push yet: make a commit first.")
    }
    let upstream = context.upstream(of: branch).flatMap { $0.remote == "." ? nil : $0 }
    let remote = try upstream?.remote ?? context.defaultRemote()
    let destination = upstream?.mergeRef ?? "refs/heads/\(branch)"
    guard let url = context.config.value("remote.\(remote).url") else {
      throw GitEngineError.notFound("There's no remote named \(remote).")
    }
    let receivePack = try await ReceivePack.connect(url)
    let advertised = receivePack.advertisement.refs
    let old = advertised.first { $0.name == destination }?.id ?? .zero
    if old != local {
      if !old.isZero {
        guard context.objects.contains(old) else {
          throw GitEngineError.refused("The remote's \(shortName(destination)) has commits you don't have. Pull first.")
        }
        guard try RevWalk.isAncestor(context.objects, old, of: local) else {
          throw GitEngineError.refused(
            "The remote's \(shortName(destination)) has commits you don't have. Pull, then push again.")
        }
      }
      // Commits the remote has, so they and their files aren't sent again.
      let haves = advertised.compactMap { ref -> ObjectID? in
        guard context.objects.contains(ref.id) else { return nil }
        return try? context.objects.commitID(peeling: ref.id)
      }
      let objects = try PackWriter.objectsMissing(from: haves, toReach: local, store: context.objects)
      progress?("Counting objects: \(objects.count), done.")
      let pack = try PackWriter.pack(objects, from: context.objects, progress: progress)
      try await receivePack.push(ref: destination, old: old, new: local, pack: pack, progress: progress)
    }
    // Record what the remote now has, and track it.
    if let tracking = context.fetchRefspecs(remote).lazy.compactMap({ $0.map(destination) }).first {
      try context.refs.update(tracking, to: local, message: "update by push")
    }
    if upstream == nil {
      try context.updateConfig { config in
        try config.set("branch.\(branch).remote", remote)
        try config.set("branch.\(branch).merge", destination)
      }
    }
  }

  /// Clones `remote` (HTTPS) into `url`, which must not exist or be empty: fetches every branch, checks out the
  /// remote's default branch and sets `origin` and the branch's upstream as `git clone` does.
  @concurrent public static func clone(
    from remote: String, to url: URL, progress: (@Sendable (String) -> Void)? = nil
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
      let context = try repository.context()
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
        var index = GitIndex()
        try Checkout(context: context).move(
          from: nil, to: context.objects.commit(defaultBranch.id).tree, index: &index)
        try context.writeIndex(index)
      } else if let target = headRef?.symrefTarget {
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

/// Fetches a remote's branches and tags into the repository.
struct Fetcher {
  let context: GitContext

  /// Fetches `remote` and returns the refs it advertised.
  func fetch(_ remote: String, progress: (@Sendable (String) -> Void)?) async throws -> [RemoteRef] {
    guard let url = context.config.value("remote.\(remote).url") else {
      throw GitEngineError.notFound("There's no remote named \(remote).")
    }
    let uploadPack = try await UploadPack.connect(url)
    let refs = try await uploadPack.listRefs()
    let refspecs = context.fetchRefspecs(remote)
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
    let tags = refs.filter { $0.name.hasPrefix("refs/tags/") && context.refs.resolve($0.name) == nil }
    var wants = Set(updates.map(\.id).filter { !store.contains($0) })
    // A new tag on a commit already here.
    for tag in tags where !store.contains(tag.id) && store.contains(tag.peeled ?? tag.id) { wants.insert(tag.id) }

    if !wants.isEmpty {
      // Branch tips we have, so the server leaves out what they already reach.
      var haves: [ObjectID] = []
      var seen = Set<ObjectID>()
      for prefix in ["refs/heads/", "refs/remotes/"] {
        for (_, id) in context.refs.list(prefix) where store.contains(id) && seen.insert(id).inserted { haves.append(id) }
      }
      let indexer = try PackIndexer(
        packDirectory: context.gitDirectory.appendingPathComponent("objects/pack"), progress: progress)
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
    let fetched = Set(updates.map(\.local))
    for refspec in refspecs where refspec.destination.hasSuffix("/*") {
      let prefix = String(refspec.destination.dropLast())
      for (name, _) in context.refs.list(prefix) where !fetched.contains(name) && !context.refs.isSymbolic(name) {
        try context.refs.delete(name)
      }
    }
    for tag in tags where store.contains(tag.id) {
      try context.refs.update(tag.name, to: tag.id, expected: .zero, message: "fetch: tag")
    }
    return refs
  }
}
