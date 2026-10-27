import Foundation

/// A SHA-1 object name: 20 bytes held as three integers, so it hashes and compares quickly. The integers are read
/// big-endian, so comparing IDs orders them the way the bytes (and pack indexes) do.
struct ObjectID: Hashable, Comparable, Sendable, CustomStringConvertible {
  private var high: UInt64
  private var middle: UInt64
  private var low: UInt32

  static let zero = ObjectID(high: 0, middle: 0, low: 0)
  /// The empty tree, which every repository has without storing it.
  static let emptyTree = ObjectID(hex: "4b825dc642cb6eb9a060e54bf8d69288fbee4904")!

  private init(high: UInt64, middle: UInt64, low: UInt32) {
    self.high = high
    self.middle = middle
    self.low = low
  }

  /// The first 20 bytes of `bytes`.
  init<Bytes: Collection<UInt8>>(bytes: Bytes) {
    var iterator = bytes.makeIterator()
    func next(_ count: Int) -> UInt64 {
      var value: UInt64 = 0
      for _ in 0..<count { value = value << 8 | UInt64(iterator.next() ?? 0) }
      return value
    }
    high = next(8)
    middle = next(8)
    low = UInt32(next(4))
  }

  /// Reads 20 bytes at `offset`.
  init(_ buffer: UnsafeRawBufferPointer, at offset: Int) {
    self.init(bytes: UnsafeRawBufferPointer(rebasing: buffer[offset..<offset + 20]))
  }

  /// 40 hexadecimal digits.
  init?(hex: some StringProtocol) {
    let digits = Array(hex.utf8)
    guard digits.count == 40 else { return nil }
    var bytes = [UInt8](repeating: 0, count: 20)
    for index in 0..<20 {
      guard let upper = Self.nibble(digits[index * 2]), let lower = Self.nibble(digits[index * 2 + 1]) else {
        return nil
      }
      bytes[index] = upper << 4 | lower
    }
    self.init(bytes: bytes)
  }

  static func nibble(_ digit: UInt8) -> UInt8? {
    switch digit {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
    default: nil
    }
  }

  var bytes: [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(20)
    for value in [high, middle] {
      for shift in stride(from: 56, through: 0, by: -8) {
        result.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
      }
    }
    result.append(contentsOf: bigEndianBytes(low))
    return result
  }

  /// The first byte, which picks the fan-out slot in a pack index.
  var firstByte: UInt8 { UInt8(truncatingIfNeeded: high >> 56) }

  var hex: String {
    let digits = Array("0123456789abcdef".utf8)
    var text: [UInt8] = []
    text.reserveCapacity(40)
    for byte in bytes {
      text.append(digits[Int(byte >> 4)])
      text.append(digits[Int(byte & 0xF)])
    }
    return String(decoding: text, as: UTF8.self)
  }

  var description: String { hex }
  var isZero: Bool { self == .zero }

  static func < (lhs: ObjectID, rhs: ObjectID) -> Bool {
    (lhs.high, lhs.middle, lhs.low) < (rhs.high, rhs.middle, rhs.low)
  }
}

/// A 32-bit number as git's files store it, most significant byte first.
func bigEndianBytes(_ value: UInt32) -> [UInt8] {
  [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}
