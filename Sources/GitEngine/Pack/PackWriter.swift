import CryptoKit
import Foundation

/// Writes a version 2 pack of whole (undeltified) objects, for pushing.
enum PackWriter {
  static func pack(_ ids: [ObjectID], from store: ObjectStore, progress: (@Sendable (String) -> Void)? = nil) throws
    -> Data
  {
    var data = Data("PACK".utf8)
    data.append(contentsOf: [0, 0, 0, 2])
    data.append(contentsOf: bigEndianBytes(UInt32(ids.count)))
    var lastPercent = -1
    for (number, id) in ids.enumerated() {
      let object = try store.read(id)
      data.append(contentsOf: PackVarint.encodeEntryHeader(type: object.type.rawValue, size: object.data.count))
      data.append(try Zlib.deflate(object.data))
      let percent = (number + 1) * 100 / max(ids.count, 1)
      if percent != lastPercent, let progress {
        lastPercent = percent
        progress("Writing objects: \(percent)% (\(number + 1)/\(ids.count))\(number + 1 == ids.count ? ", done." : "")")
      }
    }
    data.append(contentsOf: Insecure.SHA1.hash(data: data))
    return data
  }

  /// The objects a remote that has `haves` lacks to reach `tip`: the commits only `tip` reaches, and the trees and
  /// blobs of those commits that the commits just below them don't already have.
  static func objectsMissing(from haves: [ObjectID], toReach tip: ObjectID, store: ObjectStore) throws -> [ObjectID] {
    let commits = try RevWalk.exclusive(store, left: [tip], right: haves).left
    let commitSet = Set(commits)
    var known = Set<ObjectID>()
    for commit in commits {
      for parent in try store.commit(commit).parents where !commitSet.contains(parent) && store.contains(parent) {
        try collectTree(try store.commit(parent).tree, store: store, into: &known)
      }
    }
    var result = commits
    var added = Set<ObjectID>()
    for commit in commits {
      try collectNew(try store.commit(commit).tree, store: store, known: known, added: &added, into: &result)
    }
    return result
  }

  private static func collectTree(_ tree: ObjectID, store: ObjectStore, into known: inout Set<ObjectID>) throws {
    guard known.insert(tree).inserted else { return }
    for entry in try store.tree(tree) where entry.mode != .gitlink {
      if entry.mode == .tree {
        try collectTree(entry.id, store: store, into: &known)
      } else {
        known.insert(entry.id)
      }
    }
  }

  private static func collectNew(
    _ tree: ObjectID, store: ObjectStore, known: Set<ObjectID>, added: inout Set<ObjectID>,
    into result: inout [ObjectID]
  ) throws {
    guard !known.contains(tree), added.insert(tree).inserted else { return }
    result.append(tree)
    for entry in try store.tree(tree) where entry.mode != .gitlink {
      if entry.mode == .tree {
        try collectNew(entry.id, store: store, known: known, added: &added, into: &result)
      } else if !known.contains(entry.id), added.insert(entry.id).inserted {
        result.append(entry.id)
      }
    }
  }
}
