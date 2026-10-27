import Foundation
import GitKit

/// A path that differs between two snapshots (trees or the index).
struct PathChange: Equatable {
  var path: String
  var originalPath: String?
  var kind: ChangeKind
  var old: TreeFile?
  var new: TreeFile?
  var similarity: Int?
}

enum TreeDiff {
  /// Paths that differ between `old` and `new`, sorted, with renames found when `renames` is set.
  static func changes(
    old: [String: TreeFile], new: [String: TreeFile], renames: Bool, store: ObjectStore
  ) -> [PathChange] {
    var changes: [PathChange] = []
    for (path, newFile) in new {
      guard let oldFile = old[path] else {
        changes.append(PathChange(path: path, kind: .added, new: newFile))
        continue
      }
      guard oldFile != newFile else { continue }
      let typeChanged = oldFile.mode.isFile != newFile.mode.isFile
      changes.append(PathChange(path: path, kind: typeChanged ? .typeChanged : .modified, old: oldFile, new: newFile))
    }
    for (path, oldFile) in old where new[path] == nil {
      changes.append(PathChange(path: path, kind: .deleted, old: oldFile))
    }
    if renames { changes = RenameDetector.pair(changes, store: store) }
    return changes.sorted { pathPrecedes($0.path, $1.path) }
  }
}

/// Finds renames among added and deleted files: identical blobs first, then git's similarity estimate (at least 50%
/// of the bytes in common, counted by line).
enum RenameDetector {
  /// Above this many candidate pairs only identical blobs count as renames, like git's rename limit.
  static let pairLimit = 100 * 100
  static let minimumScore = 50

  static func pair(_ changes: [PathChange], store: ObjectStore) -> [PathChange] {
    var added = changes.indices.filter { changes[$0].kind == .added && changes[$0].new?.mode.isFile == true }
    var deleted = changes.indices.filter { changes[$0].kind == .deleted && changes[$0].old?.mode.isFile == true }
    guard !added.isEmpty, !deleted.isEmpty else { return changes }
    var result = changes
    var consumed = Set<Int>()

    func rename(from source: Int, to target: Int, score: Int) {
      result[target].kind = .renamed
      result[target].originalPath = changes[source].path
      result[target].old = changes[source].old
      result[target].similarity = score
      consumed.insert(source)
    }

    // Identical contents.
    var byBlob: [ObjectID: [Int]] = [:]
    for index in deleted { byBlob[changes[index].old!.id, default: []].append(index) }
    added.removeAll { target in
      guard var sources = byBlob[changes[target].new!.id], !sources.isEmpty else { return false }
      let exactName = sources.firstIndex { name(changes[$0].path) == name(changes[target].path) } ?? 0
      let source = sources.remove(at: exactName)
      byBlob[changes[target].new!.id] = sources
      rename(from: source, to: target, score: 100)
      return true
    }
    deleted.removeAll { consumed.contains($0) }

    if !added.isEmpty, !deleted.isEmpty, added.count * deleted.count <= pairLimit {
      var signatures: [Int: (size: Int, chunks: [Int: Int])] = [:]
      func signature(_ index: Int, _ file: TreeFile) -> (size: Int, chunks: [Int: Int])? {
        if let cached = signatures[index] { return cached }
        guard let data = try? store.read(file.id).data, !DiffBuilder.isBinary(data) else { return nil }
        let value = (data.count, chunkCounts(data))
        signatures[index] = value
        return value
      }
      var candidates: [(score: Int, source: Int, target: Int)] = []
      for target in added {
        guard let targetSignature = signature(target, changes[target].new!) else { continue }
        for source in deleted {
          guard let sourceSignature = signature(source, changes[source].old!) else { continue }
          let score = similarity(sourceSignature, targetSignature)
          if score >= minimumScore { candidates.append((score, source, target)) }
        }
      }
      var used = Set<Int>()
      for candidate in candidates.sorted(by: { $0.score > $1.score }) {
        guard !consumed.contains(candidate.source), !used.contains(candidate.target) else { continue }
        used.insert(candidate.target)
        rename(from: candidate.source, to: candidate.target, score: candidate.score)
      }
    }
    return result.indices.filter { !consumed.contains($0) }.map { result[$0] }
  }

  private static func name(_ path: String) -> Substring { path.split(separator: "/").last ?? Substring(path) }

  /// Bytes per chunk hash; a chunk is a line, or 64 bytes of a longer one.
  static func chunkCounts(_ data: Data) -> [Int: Int] {
    var counts: [Int: Int] = [:]
    data.withUnsafeBytes { buffer in
      var start = 0
      var hasher = Hasher()
      for index in 0..<buffer.count {
        hasher.combine(buffer[index])
        if buffer[index] == 0x0A || index - start == 63 {
          counts[hasher.finalize(), default: 0] += index - start + 1
          hasher = Hasher()
          start = index + 1
        }
      }
      if start < buffer.count { counts[hasher.finalize(), default: 0] += buffer.count - start }
    }
    return counts
  }

  static func similarity(_ source: (size: Int, chunks: [Int: Int]), _ target: (size: Int, chunks: [Int: Int])) -> Int {
    let larger = max(source.size, target.size)
    guard larger > 0 else { return 100 }
    // Too different in size to reach the minimum.
    if abs(source.size - target.size) * 100 > larger * (100 - minimumScore) { return 0 }
    var common = 0
    for (hash, bytes) in source.chunks { common += min(bytes, target.chunks[hash] ?? 0) }
    return common * 100 / larger
  }
}
