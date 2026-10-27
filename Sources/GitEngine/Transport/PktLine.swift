import Foundation

/// git's pkt-line framing: four hex digits of length (including themselves), then the payload; `0000` ends a
/// message (flush), `0001` separates sections (delimiter) and `0002` ends a response (protocol v2).
enum PktLine: Equatable {
  case data([UInt8])
  case flush
  case delimiter
  case responseEnd

  static let maxPayload = 65516

  static func encode(_ text: String) -> Data { encode(Array(text.utf8)) }

  static func encode(_ payload: [UInt8]) -> Data {
    var data = Data(String(format: "%04x", payload.count + 4).utf8)
    data.append(contentsOf: payload)
    return data
  }

  static let flushPacket = Data("0000".utf8)
  static let delimiterPacket = Data("0001".utf8)

  /// The payload as text without its trailing newline.
  var text: String? {
    guard case .data(let bytes) = self else { return nil }
    var text = String(decoding: bytes, as: UTF8.self)
    if text.hasSuffix("\n") { text.removeLast() }
    return text
  }
}

/// Reads pkt-lines (and, after a v0 negotiation without side-band, raw bytes) from a byte stream.
struct PktLineReader<Source: AsyncIteratorProtocol> where Source.Element == UInt8 {
  private var source: Source

  init(_ source: Source) {
    self.source = source
  }

  /// Exactly `count` bytes, or `nil` when the stream ends first.
  @concurrent mutating func read(_ count: Int) async throws -> [UInt8]? {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(count)
    while bytes.count < count {
      guard let byte = try await source.next() else { return bytes.isEmpty ? nil : bytes }
      bytes.append(byte)
    }
    return bytes
  }

  /// The next packet, or `nil` at the end of the stream.
  @concurrent mutating func next() async throws -> PktLine? {
    guard let header = try await read(4) else { return nil }
    guard header.count == 4, let length = Int(String(decoding: header, as: UTF8.self), radix: 16) else {
      throw GitEngineError.network("The server sent a malformed response.")
    }
    switch length {
    case 0: return .flush
    case 1: return .delimiter
    case 2: return .responseEnd
    case 3: throw GitEngineError.network("The server sent a malformed response.")
    default:
      guard let payload = try await read(length - 4), payload.count == length - 4 else {
        throw GitEngineError.network("The server's response ended early.")
      }
      return .data(payload)
    }
  }

  /// The rest of the stream in pieces, for a pack sent without side-band.
  @concurrent mutating func nextChunk(_ size: Int = 64 * 1024) async throws -> [UInt8]? {
    try await read(size)
  }
}

/// A byte iterator over in-memory data, for advertisements already downloaded and for tests.
struct DataByteIterator: AsyncIteratorProtocol {
  private let bytes: [UInt8]
  private var position = 0

  init(_ data: Data) {
    bytes = [UInt8](data)
  }

  mutating func next() async throws -> UInt8? {
    guard position < bytes.count else { return nil }
    defer { position += 1 }
    return bytes[position]
  }
}
