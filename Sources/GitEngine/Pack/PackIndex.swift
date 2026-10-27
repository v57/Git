import Foundation

/// A version 2 `.idx` file: the sorted object IDs of one pack and where each one starts.
final class PackIndex {
  let url: URL
  private let data: Data
  let count: Int

  private static let magic: [UInt8] = [0xFF, 0x74, 0x4F, 0x63]

  init(url: URL) throws {
    self.url = url
    data = try Data(contentsOf: url, options: .alwaysMapped)
    count = try data.withUnsafeBytes { buffer in
      guard buffer.count >= 8 + 1024 + 40, Array(buffer[0..<4]) == Self.magic else {
        throw GitEngineError.corrupt("\(url.lastPathComponent) is a pack index version the engine doesn't read.")
      }
      guard Self.uint32(buffer, 4) == 2 else {
        throw GitEngineError.corrupt("\(url.lastPathComponent) is a pack index version the engine doesn't read.")
      }
      let count = Int(Self.uint32(buffer, 8 + 255 * 4))
      guard buffer.count >= 8 + 1024 + count * 28 + 40 else {
        throw GitEngineError.corrupt("\(url.lastPathComponent) is truncated.")
      }
      return count
    }
  }

  static func uint32(_ buffer: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
    UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16 | UInt32(buffer[offset + 2]) << 8
      | UInt32(buffer[offset + 3])
  }

  private var namesStart: Int { 8 + 1024 }

  private func range(for firstByte: UInt8, _ buffer: UnsafeRawBufferPointer) -> Range<Int> {
    let lower = firstByte == 0 ? 0 : Int(Self.uint32(buffer, 8 + (Int(firstByte) - 1) * 4))
    let upper = Int(Self.uint32(buffer, 8 + Int(firstByte) * 4))
    return lower..<max(lower, upper)
  }

  /// The pack offset of `id`, or `nil` when this pack doesn't have it.
  func offset(of id: ObjectID) -> Int? {
    data.withUnsafeBytes { buffer in
      var range = range(for: id.firstByte, buffer)
      while !range.isEmpty {
        let middle = (range.lowerBound + range.upperBound) / 2
        let candidate = ObjectID(buffer, at: namesStart + middle * 20)
        if candidate == id { return offset(at: middle, buffer) }
        if candidate < id { range = (middle + 1)..<range.upperBound } else { range = range.lowerBound..<middle }
      }
      return nil
    }
  }

  private func offset(at position: Int, _ buffer: UnsafeRawBufferPointer) -> Int {
    let small = Self.uint32(buffer, namesStart + count * 24 + position * 4)
    guard small & 0x8000_0000 != 0 else { return Int(small) }
    let large = namesStart + count * 28 + Int(small & 0x7FFF_FFFF) * 8
    return Int(Self.uint32(buffer, large)) << 32 | Int(Self.uint32(buffer, large + 4))
  }

  /// Every ID whose hex form starts with `prefix` (lowercase).
  func ids(withPrefix prefix: String) -> [ObjectID] {
    guard prefix.count >= 2, let first = UInt8(prefix.prefix(2), radix: 16) else { return [] }
    return data.withUnsafeBytes { buffer in
      range(for: first, buffer).compactMap { position in
        let id = ObjectID(buffer, at: namesStart + position * 20)
        return id.hex.hasPrefix(prefix) ? id : nil
      }
    }
  }

  /// Every object in the pack with its offset.
  func entries() -> [(id: ObjectID, offset: Int)] {
    data.withUnsafeBytes { buffer in
      (0..<count).map { (ObjectID(buffer, at: namesStart + $0 * 20), offset(at: $0, buffer)) }
    }
  }
}
