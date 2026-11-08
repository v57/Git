import Foundation
import GitKit

/// Pushes branches, as `git push` does with this repository's settings.
struct Pusher {
  let context: GitContext

  /// Pushes the current branch to every address of its push remote.
  func push(force: Bool, progress: (@Sendable (String) -> Void)?) async throws {
    guard let branch = try context.head().branchName else {
      throw GitEngineError.refused("HEAD is detached. Switch to a branch before pushing.")
    }
    guard let local = context.refs.resolve("refs/heads/\(branch)") else {
      throw GitEngineError.refused("There's nothing to push yet: make a commit first.")
    }
    let upstream = context.upstream(of: branch).flatMap { $0.remote == "." ? nil : $0 }
    let remote = try context.pushRemote(for: branch)
    guard remote != "." else { throw GitEngineError.unsupported("This branch pushes to this repository itself.") }
    let destination = try self.destination(of: branch, on: remote, upstream: upstream)
    let tracking = context.fetchRefspecs(remote).lazy.compactMap { $0.map(destination) }.first
    // `--force-with-lease` without a value: the remote must be where it was when last fetched.
    let lease = force ? (tracking.flatMap { context.refs.resolve($0) } ?? .zero) : nil
    for url in try context.pushURLs(remote) {
      let receivePack = try await ReceivePack.connect(url)
      defer { receivePack.transport.close() }
      if let format = receivePack.advertisement.capabilities["object-format"], format != "sha1" {
        throw GitEngineError.unsupported("\(remote) uses \(format) object IDs, which Git in the app doesn't read yet.")
      }
      let advertised = receivePack.advertisement.refs
      let old = advertised.first { $0.name == destination }?.id ?? .zero
      guard old != local else { continue }
      if let lease {
        guard old == lease else {
          throw GitEngineError.refused(
            "The remote's \(shortName(destination)) has commits you haven't fetched. Fetch, look at them, and try again.")
        }
      } else if !old.isZero {
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
    if let tracking { try context.refs.update(tracking, to: local, message: "update by push") }
    if upstream == nil {
      try context.updateConfig { config in
        try config.set("branch.\(branch).remote", remote)
        try config.set("branch.\(branch).merge", destination)
      }
    }
  }

  /// Which branch of `remote` a `git push` of `branch` updates: with an upstream, what `push.default` says; without
  /// one, the same name, as `git push --set-upstream <remote> HEAD`.
  private func destination(of branch: String, on remote: String, upstream: Upstream?) throws -> String {
    let same = "refs/heads/\(branch)"
    guard let upstream else { return same }
    switch context.settings.value("push.default")?.lowercased() ?? "simple" {
    case "current": return same
    case "upstream", "tracking":
      guard upstream.remote == remote else {
        throw GitEngineError.refused("\(branch) pushes to \(remote), which isn't where its upstream is.")
      }
      return upstream.mergeRef
    case "simple":
      guard upstream.remote == remote, upstream.mergeRef != same else { return same }
      throw GitEngineError.refused(
        "\(branch) tracks \(upstream.shortName), which has another name. Push it with git, or set its upstream again.")
    case let other:
      throw GitEngineError.unsupported("push.default is \(other), which Git in the app doesn't do.")
    }
  }

  /// Sends tag `name` to every address of `remote`, as `git push <remote> refs/tags/<name>`: the tag object of an
  /// annotated tag, and whatever it tags that the remote lacks. A remote that already has the tag at this object is
  /// left as it is; one that has it at another object is refused, never moved.
  func pushTag(_ name: String, to remote: String, progress: (@Sendable (String) -> Void)?) async throws {
    let ref = "refs/tags/\(name)"
    guard let local = context.refs.resolve(ref) else {
      throw GitEngineError.refused("There's no tag \(name) in this repository.")
    }
    guard remote != "." else { throw GitEngineError.unsupported("This tag pushes to this repository itself.") }
    // The tag objects down to what they tag: an annotated tag can tag another tag.
    var tagObjects: [ObjectID] = []
    var target = local
    for _ in 0..<32 {
      let object = try context.objects.read(target)
      guard object.type == .tag else { break }
      tagObjects.append(target)
      target = try TagObject(object.data).object
    }
    let targetType = try context.objects.read(target).type
    for url in try context.pushURLs(remote) {
      let receivePack = try await ReceivePack.connect(url)
      defer { receivePack.transport.close() }
      if let format = receivePack.advertisement.capabilities["object-format"], format != "sha1" {
        throw GitEngineError.unsupported("\(remote) uses \(format) object IDs, which Git in the app doesn't read yet.")
      }
      let advertised = receivePack.advertisement.refs
      if let old = advertised.first(where: { $0.name == ref })?.id {
        guard old == local else { throw refusal(name, remote: remote, theirs: old, ours: local) }
        progress?("\(name) is already on \(remote).")
        continue
      }
      // Commits the remote has, so they and their files aren't sent again.
      let haves = advertised.compactMap { ref -> ObjectID? in
        guard context.objects.contains(ref.id) else { return nil }
        return try? context.objects.commitID(peeling: ref.id)
      }
      var objects = tagObjects
      switch targetType {
      case .commit: objects += try PackWriter.objectsMissing(from: haves, toReach: target, store: context.objects)
      case .tree: objects += try Self.everything(inTree: target, store: context.objects)
      default: objects.append(target)
      }
      progress?("Counting objects: \(objects.count), done.")
      let pack = try PackWriter.pack(objects, from: context.objects, progress: progress)
      try await receivePack.push(ref: ref, old: .zero, new: local, pack: pack, progress: progress)
    }
  }

  /// Why a tag isn't sent: the remote's has the same name and another object.
  private func refusal(_ name: String, remote: String, theirs: ObjectID, ours: ObjectID) -> GitEngineError {
    let short = String(theirs.hex.prefix(7))
    if context.objects.contains(theirs), let theirCommit = try? context.objects.commitID(peeling: theirs),
      theirCommit == (try? context.objects.commitID(peeling: ours))
    {
      return .refused(
        "\(remote) already has a tag \(name) on the same commit, made another way (\(short)). Tags there aren't replaced.")
    }
    return .refused(
      "\(remote) already has a tag \(name) on another commit (\(short)). Tags there aren't moved: give this one another name.")
  }

  /// A tree and everything in it, for a tag that tags a tree.
  private static func everything(inTree tree: ObjectID, store: ObjectStore) throws -> [ObjectID] {
    var result = [tree]
    for entry in try store.tree(tree) where entry.mode != .gitlink {
      result += entry.mode == .tree ? try everything(inTree: entry.id, store: store) : [entry.id]
    }
    return result
  }

  /// Deletes `branch` on every address of `remote`, unless it moved past `expected`.
  func delete(_ branch: String, on remote: String, expected: ObjectID, progress: (@Sendable (String) -> Void)?) async throws {
    let ref = "refs/heads/\(branch)"
    for url in try context.pushURLs(remote) {
      let receivePack = try await ReceivePack.connect(url)
      defer { receivePack.transport.close() }
      guard let old = receivePack.advertisement.refs.first(where: { $0.name == ref })?.id else {
        throw GitEngineError.refused("\(branch) isn't on \(remote) any more. Fetch to see that here.")
      }
      guard old == expected else {
        throw GitEngineError.refused("\(remote)/\(branch) has commits you haven't fetched. Fetch, look at them, and try again.")
      }
      guard receivePack.advertisement.supports("delete-refs") else {
        throw GitEngineError.refused("\(remote) doesn't let branches be deleted.")
      }
      try await receivePack.push(ref: ref, old: old, new: .zero, pack: nil, progress: progress)
    }
    for tracking in context.fetchRefspecs(remote).compactMap({ $0.map(ref) }) where context.refs.read(tracking) != nil {
      try context.refs.delete(tracking)
    }
  }
}
