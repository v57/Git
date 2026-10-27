import Foundation

/// Pushing to a server's `git-receive-pack` (protocol v0, the only one it speaks).
struct ReceivePack {
  let transport: SmartHTTP
  let advertisement: Advertisement

  static let service = "git-receive-pack"

  static func connect(_ remote: String) async throws -> ReceivePack {
    let (transport, data) = try await SmartHTTP.discover(remote, service: service, version2: false)
    return ReceivePack(transport: transport, advertisement: try await Advertisement.parse(data))
  }

  /// Updates `ref` from `old` to `new`, sending `pack`. Throws with the server's reason when it refuses.
  func push(
    ref: String, old: ObjectID, new: ObjectID, pack: Data?, progress: (@Sendable (String) -> Void)?
  ) async throws {
    let sideband = advertisement.supports("side-band-64k")
    var capabilities = ["report-status"]
    if sideband { capabilities.append("side-band-64k") }
    if progress == nil, advertisement.supports("quiet") { capabilities.append("quiet") }
    if advertisement.supports("agent") { capabilities.append("agent=\(SmartHTTP.agent)") }
    // The capabilities follow the first command after a NUL.
    let command = Array("\(old.hex) \(new.hex) \(ref)".utf8)
    var body = PktLine.encode(command + [0] + Array(capabilities.joined(separator: " ").utf8) + [0x0A])
    body.append(PktLine.flushPacket)
    if let pack { body.append(pack) }

    var reader = PktLineReader(try await transport.post(Self.service, body: body, version2: false).makeAsyncIterator())
    var report: [String] = []
    if sideband {
      // The report is pkt-lines inside band 1.
      var bands = SideBand(progress: progress)
      var inner = Data()
      while let packet = try await reader.next(), case .data(let bytes) = packet {
        if let data = try bands.handle(bytes) { inner.append(contentsOf: data) }
      }
      bands.flush()
      var innerReader = PktLineReader(DataByteIterator(inner))
      while let packet = try await innerReader.next(), let line = packet.text { report.append(line) }
    } else {
      while let packet = try await reader.next(), let line = packet.text { report.append(line) }
    }
    try Self.check(report, ref: ref)
  }

  /// `unpack ok`, then `ok <ref>` or `ng <ref> <reason>`.
  static func check(_ report: [String], ref: String) throws {
    guard let unpack = report.first(where: { $0.hasPrefix("unpack ") }) else {
      throw GitEngineError.network("The server didn't say whether the push worked.")
    }
    guard unpack == "unpack ok" else {
      throw GitEngineError.network("The server couldn't store the pushed commits: \(unpack.dropFirst(7)).")
    }
    for line in report {
      if line.hasPrefix("ng ") {
        let reason = line.dropFirst(3).split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        let name = shortName(ref)
        if reason.contains("non-fast-forward") || reason.contains("fetch first") {
          throw GitEngineError.refused("The remote's \(name) has commits you don't have. Pull, then push again.")
        }
        throw GitEngineError.refused("The server refused to update \(name): \(reason).")
      }
    }
    guard report.contains("ok \(ref)") else {
      throw GitEngineError.network("The server didn't confirm the push.")
    }
  }
}
