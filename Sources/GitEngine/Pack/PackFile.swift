import Foundation

/// A `.pack` file with its index, read through a memory map.
final class PackFile {
  let index: PackIndex
  private let data: Data

  static let ofsDelta = 6
  static let refDelta = 7

  init(index: PackIndex) throws {
    self.index = index
    let url = index.url.deletingPathExtension().appendingPathExtension("pack")
    data = try Data(contentsOf: url, options: .alwaysMapped)
    try data.withUnsafeBytes { buffer in
      guard buffer.count >= 32, Array(buffer[0..<4]) == Array("PACK".utf8) else {
        throw GitEngineError.corrupt("\(url.lastPathComponent) isn't a pack file.")
      }
    }
  }

  /// What a stored entry is: a whole object, or a delta against a base at an offset or with an ID.
  enum Base {
    case none
    case offset(Int)
    case id(ObjectID)
  }

  struct Entry {
    var type: Int
    var size: Int
    var base: Base
    /// Where the zlib data starts.
    var dataOffset: Int
  }

  func entry(at offset: Int) throws -> Entry {
    try data.withUnsafeBytes { buffer in
      guard let header = PackVarint.entryHeader(buffer, at: offset) else {
        throw GitEngineError.corrupt("A pack entry is damaged.")
      }
      var position = offset + header.length
      var base = Base.none
      switch header.type {
      case Self.ofsDelta:
        guard let distance = PackVarint.offset(buffer, at: position), distance.value <= offset else {
          throw GitEngineError.corrupt("A pack delta is damaged.")
        }
        base = .offset(offset - distance.value)
        position += distance.length
      case Self.refDelta:
        guard position + 20 <= buffer.count else { throw GitEngineError.corrupt("A pack delta is damaged.") }
        base = .id(ObjectID(buffer, at: position))
        position += 20
      case 1...4: break
      default: throw GitEngineError.corrupt("A pack entry has an unknown type.")
      }
      return Entry(type: header.type, size: header.size, base: base, dataOffset: position)
    }
  }

  /// The inflated data of an entry (an object's contents, or a delta's instructions).
  func inflate(_ entry: Entry) throws -> Data {
    try data.withUnsafeBytes { buffer in
      guard entry.dataOffset < buffer.count else { throw GitEngineError.corrupt("A pack entry is truncated.") }
      let result = try Zlib.inflate(
        UnsafeRawBufferPointer(rebasing: buffer[entry.dataOffset...]), expectedSize: entry.size)
      guard result.data.count == entry.size else { throw GitEngineError.corrupt("A pack entry has the wrong size.") }
      return result.data
    }
  }
}
