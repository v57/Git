import Foundation
import zlib

/// zlib's inflate and deflate, which git uses for every stored object.
enum Zlib {
  /// Inflates the zlib stream at the start of `input`. Returns the data and how many input bytes the stream took,
  /// which is where the next object in a pack starts. `expectedSize` sizes the output buffer.
  static func inflate(_ input: UnsafeRawBufferPointer, expectedSize: Int? = nil) throws -> (data: Data, consumed: Int) {
    var stream = z_stream()
    guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      throw GitEngineError.corrupt("Couldn't start zlib.")
    }
    defer { inflateEnd(&stream) }
    var output = Data(count: max(expectedSize ?? input.count * 2, 64))
    var produced = 0
    stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress?.assumingMemoryBound(to: Bytef.self))
    stream.avail_in = uInt(input.count)
    while true {
      if produced == output.count { output.count = output.count * 2 }
      let status = output.withUnsafeMutableBytes { buffer -> Int32 in
        stream.next_out = buffer.baseAddress!.advanced(by: produced).assumingMemoryBound(to: Bytef.self)
        stream.avail_out = uInt(buffer.count - produced)
        let status = zlib.inflate(&stream, Z_NO_FLUSH)
        produced = buffer.count - Int(stream.avail_out)
        return status
      }
      if status == Z_STREAM_END { break }
      // Z_BUF_ERROR with output space left means the input ran out.
      guard status == Z_OK || (status == Z_BUF_ERROR && produced == output.count) else {
        throw GitEngineError.corrupt("A compressed object is damaged.")
      }
    }
    output.count = produced
    return (output, input.count - Int(stream.avail_in))
  }

  static func inflate(_ data: Data, expectedSize: Int? = nil) throws -> Data {
    try data.withUnsafeBytes { try inflate($0, expectedSize: expectedSize).data }
  }

  static func deflate(_ data: Data, level: Int32 = Z_DEFAULT_COMPRESSION) throws -> Data {
    var stream = z_stream()
    guard deflateInit_(&stream, level, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      throw GitEngineError.corrupt("Couldn't start zlib.")
    }
    defer { deflateEnd(&stream) }
    var output = Data(count: Int(deflateBound(&stream, uLong(data.count))) + 16)
    let status = data.withUnsafeBytes { input in
      output.withUnsafeMutableBytes { buffer in
        stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress?.assumingMemoryBound(to: Bytef.self))
        stream.avail_in = uInt(input.count)
        stream.next_out = buffer.baseAddress!.assumingMemoryBound(to: Bytef.self)
        stream.avail_out = uInt(buffer.count)
        return zlib.deflate(&stream, Z_FINISH)
      }
    }
    guard status == Z_STREAM_END else { throw GitEngineError.corrupt("Couldn't compress an object.") }
    output.count = Int(stream.total_out)
    return output
  }

  static func crc32(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
    guard let base = bytes.baseAddress, !bytes.isEmpty else { return crc }
    return UInt32(zlib.crc32(uLong(crc), base.assumingMemoryBound(to: Bytef.self), uInt(bytes.count)))
  }
}

/// A zlib stream fed in pieces, for objects arriving over the network: it says when the stream ends and how many of
/// the bytes it was given belong to it.
final class StreamingInflater {
  private var stream = z_stream()
  private var scratch = [UInt8](repeating: 0, count: 64 * 1024)

  init() throws {
    guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      throw GitEngineError.corrupt("Couldn't start zlib.")
    }
  }

  deinit { inflateEnd(&stream) }

  func reset() { inflateReset(&stream) }

  /// Feeds `input`; `output` sees every inflated piece. Returns the bytes used and whether the stream ended.
  func feed(_ input: UnsafeRawBufferPointer, output: (UnsafeRawBufferPointer) -> Void) throws
    -> (used: Int, ended: Bool)
  {
    guard !input.isEmpty else { return (0, false) }
    stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress!.assumingMemoryBound(to: Bytef.self))
    stream.avail_in = uInt(input.count)
    while true {
      let (status, produced) = scratch.withUnsafeMutableBytes { buffer -> (Int32, Int) in
        stream.next_out = buffer.baseAddress!.assumingMemoryBound(to: Bytef.self)
        stream.avail_out = uInt(buffer.count)
        let status = inflate(&stream, Z_NO_FLUSH)
        let produced = buffer.count - Int(stream.avail_out)
        output(UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(buffer)[0..<produced]))
        return (status, produced)
      }
      let used = input.count - Int(stream.avail_in)
      if status == Z_STREAM_END { return (used, true) }
      guard status == Z_OK || status == Z_BUF_ERROR else {
        throw GitEngineError.corrupt("The received pack has a damaged object.")
      }
      // Out of input, or no progress possible until more arrives.
      if stream.avail_in == 0 || (status == Z_BUF_ERROR && produced == 0) { return (used, false) }
    }
  }
}
