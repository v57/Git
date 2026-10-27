import Foundation

/// git's delta format: the base and result sizes, then instructions that copy ranges of the base or insert new bytes.
enum Delta {
  static func apply(_ delta: Data, to base: Data) throws -> Data {
    try delta.withUnsafeBytes { delta in
      try base.withUnsafeBytes { base in try apply(delta, to: base) }
    }
  }

  static func apply(_ delta: UnsafeRawBufferPointer, to base: UnsafeRawBufferPointer) throws -> Data {
    var position = 0
    func size() throws -> Int {
      var value = 0
      var shift = 0
      while true {
        guard position < delta.count else { throw GitEngineError.corrupt("A delta is damaged.") }
        let byte = delta[position]
        position += 1
        value |= Int(byte & 0x7F) << shift
        shift += 7
        if byte & 0x80 == 0 { return value }
      }
    }
    guard try size() == base.count else { throw GitEngineError.corrupt("A delta doesn't fit its base.") }
    let resultSize = try size()
    var result = Data(count: resultSize)
    var written = 0
    try result.withUnsafeMutableBytes { output in
      while position < delta.count {
        let instruction = delta[position]
        position += 1
        if instruction & 0x80 != 0 {
          var offset = 0
          var length = 0
          for bit in 0..<4 where instruction & (1 << bit) != 0 {
            guard position < delta.count else { throw GitEngineError.corrupt("A delta is damaged.") }
            offset |= Int(delta[position]) << (8 * bit)
            position += 1
          }
          for bit in 0..<3 where instruction & (0x10 << bit) != 0 {
            guard position < delta.count else { throw GitEngineError.corrupt("A delta is damaged.") }
            length |= Int(delta[position]) << (8 * bit)
            position += 1
          }
          if length == 0 { length = 0x10000 }
          guard offset + length <= base.count, written + length <= resultSize else {
            throw GitEngineError.corrupt("A delta copies past its base.")
          }
          output.baseAddress!.advanced(by: written).copyMemory(
            from: base.baseAddress!.advanced(by: offset), byteCount: length)
          written += length
        } else if instruction != 0 {
          let length = Int(instruction)
          guard position + length <= delta.count, written + length <= resultSize else {
            throw GitEngineError.corrupt("A delta is damaged.")
          }
          output.baseAddress!.advanced(by: written).copyMemory(
            from: delta.baseAddress!.advanced(by: position), byteCount: length)
          position += length
          written += length
        } else {
          throw GitEngineError.corrupt("A delta has an unknown instruction.")
        }
      }
    }
    guard written == resultSize else { throw GitEngineError.corrupt("A delta is incomplete.") }
    return result
  }
}

/// Reading the variable-length numbers packs use.
enum PackVarint {
  /// An entry header: type in bits 4–6 of the first byte, size in its low 4 bits and 7 bits per following byte.
  static func entryHeader(_ buffer: UnsafeRawBufferPointer, at offset: Int) -> (type: Int, size: Int, length: Int)? {
    var position = offset
    guard position < buffer.count else { return nil }
    var byte = buffer[position]
    position += 1
    let type = Int(byte >> 4) & 7
    var size = Int(byte & 0x0F)
    var shift = 4
    while byte & 0x80 != 0 {
      guard position < buffer.count, shift < 57 else { return nil }
      byte = buffer[position]
      position += 1
      size |= Int(byte & 0x7F) << shift
      shift += 7
    }
    return (type, size, position - offset)
  }

  /// An OFS_DELTA base distance (also the index v4 path prefix length): big-endian 7-bit groups, each continuation
  /// adding one.
  static func offset(_ buffer: UnsafeRawBufferPointer, at offset: Int) -> (value: Int, length: Int)? {
    var position = offset
    guard position < buffer.count else { return nil }
    var byte = buffer[position]
    position += 1
    var value = Int(byte & 0x7F)
    while byte & 0x80 != 0 {
      guard position < buffer.count, value < Int.max >> 8 else { return nil }
      byte = buffer[position]
      position += 1
      value = ((value + 1) << 7) | Int(byte & 0x7F)
    }
    return (value, position - offset)
  }

  static func encodeEntryHeader(type: Int, size: Int) -> [UInt8] {
    var bytes: [UInt8] = []
    var size = size
    var byte = UInt8(type << 4) | UInt8(size & 0x0F)
    size >>= 4
    while size > 0 {
      bytes.append(byte | 0x80)
      byte = UInt8(size & 0x7F)
      size >>= 7
    }
    bytes.append(byte)
    return bytes
  }

  static func encodeOffset(_ value: Int) -> [UInt8] {
    var value = value
    var bytes = [UInt8(value & 0x7F)]
    value >>= 7
    while value > 0 {
      value -= 1
      bytes.insert(UInt8(0x80 | (value & 0x7F)), at: 0)
      value >>= 7
    }
    return bytes
  }
}
