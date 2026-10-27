import Foundation

/// What a server says about itself in `info/refs`: protocol v2 capabilities, or (v0) its refs and capabilities.
struct Advertisement {
  var version2 = false
  /// `name` or `name=value` capabilities.
  var capabilities: [String: String] = [:]
  /// The refs a v0 server listed.
  var refs: [RemoteRef] = []

  static func parse(_ data: Data) async throws -> Advertisement {
    var reader = PktLineReader(DataByteIterator(data))
    var advertisement = Advertisement()
    var packet = try await reader.next()
    if packet?.text?.hasPrefix("# service=") == true {
      while let next = try await reader.next(), next != .flush {}
      packet = try await reader.next()
    }
    if packet?.text == "version 2" {
      advertisement.version2 = true
      while let next = try await reader.next(), case .data = next, let line = next.text {
        advertisement.addCapability(line)
      }
      return advertisement
    }
    var symrefs: [String: String] = [:]
    while let current = packet, case .data(let bytes) = current {
      var line = bytes
      if let nul = line.firstIndex(of: 0) {
        let capabilities = String(decoding: line[(nul + 1)...], as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        for capability in capabilities.split(separator: " ") {
          advertisement.addCapability(String(capability))
          if capability.hasPrefix("symref=") {
            let mapping = capability.dropFirst(7).split(separator: ":", maxSplits: 1)
            if mapping.count == 2 { symrefs[String(mapping[0])] = String(mapping[1]) }
          }
        }
        line = Array(line[..<nul])
      }
      let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      let parts = text.split(separator: " ", maxSplits: 1)
      if parts.count == 2, let id = ObjectID(hex: parts[0]), parts[1] != "capabilities^{}" {
        let name = String(parts[1])
        if name.hasSuffix("^{}") {
          let tag = String(name.dropLast(3))
          if let index = advertisement.refs.firstIndex(where: { $0.name == tag }) {
            advertisement.refs[index].peeled = id
          }
        } else {
          advertisement.refs.append(RemoteRef(name: name, id: id))
        }
      }
      packet = try await reader.next()
    }
    for index in advertisement.refs.indices {
      advertisement.refs[index].symrefTarget = symrefs[advertisement.refs[index].name]
    }
    return advertisement
  }

  private mutating func addCapability(_ line: String) {
    let parts = line.split(separator: "=", maxSplits: 1)
    capabilities[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
  }

  func supports(_ capability: String) -> Bool { capabilities[capability] != nil }

  /// Whether a v2 command has a feature, e.g. `fetch` with `shallow`.
  func supports(_ command: String, feature: String) -> Bool {
    capabilities[command]?.split(separator: " ").contains(Substring(feature)) ?? false
  }
}

/// Fetching from a server's `git-upload-pack`, in protocol v2 when it speaks it and v0 otherwise.
struct UploadPack {
  let transport: SmartHTTP
  let advertisement: Advertisement

  static let service = "git-upload-pack"

  static func connect(_ remote: String) async throws -> UploadPack {
    let (transport, data) = try await SmartHTTP.discover(remote, service: service, version2: true)
    return UploadPack(transport: transport, advertisement: try await Advertisement.parse(data))
  }

  /// The server's branches and tags, and where its HEAD points.
  func listRefs() async throws -> [RemoteRef] {
    guard advertisement.version2 else { return advertisement.refs }
    var body = command("ls-refs")
    for argument in ["peel", "symrefs", "ref-prefix HEAD", "ref-prefix refs/heads/", "ref-prefix refs/tags/"] {
      body.append(PktLine.encode(argument + "\n"))
    }
    body.append(PktLine.flushPacket)
    var reader = PktLineReader(try await transport.post(Self.service, body: body, version2: true).makeAsyncIterator())
    var refs: [RemoteRef] = []
    while let packet = try await reader.next(), let line = packet.text {
      // `<id> <name>[ symref-target:<ref>][ peeled:<id>]`; an unborn HEAD starts with `unborn`.
      let fields = line.split(separator: " ")
      guard fields.count >= 2, let id = ObjectID(hex: fields[0]) else { continue }
      var ref = RemoteRef(name: String(fields[1]), id: id)
      for attribute in fields.dropFirst(2) {
        if attribute.hasPrefix("symref-target:") { ref.symrefTarget = String(attribute.dropFirst(14)) }
        if attribute.hasPrefix("peeled:") { ref.peeled = ObjectID(hex: attribute.dropFirst(7)) }
      }
      refs.append(ref)
    }
    return refs
  }

  /// The start of a v2 command: its name, the capabilities we send, the delimiter.
  private func command(_ name: String) -> Data {
    var body = PktLine.encode("command=\(name)\n")
    if advertisement.supports("agent") { body.append(PktLine.encode("agent=\(SmartHTTP.agent)\n")) }
    if advertisement.capabilities["object-format"] != nil { body.append(PktLine.encode("object-format=sha1\n")) }
    body.append(PktLine.delimiterPacket)
    return body
  }

  /// Asks for `wants` (telling the server about `haves`) and feeds the pack into `indexer`; progress lines from the
  /// server go to `progress`.
  func fetch(
    wants: [ObjectID], haves: [ObjectID], indexer: PackIndexer, progress: (@Sendable (String) -> Void)?
  ) async throws {
    let body: Data
    if advertisement.version2 {
      var data = command("fetch")
      data.append(PktLine.encode("ofs-delta\n"))
      data.append(PktLine.encode("include-tag\n"))
      if progress == nil { data.append(PktLine.encode("no-progress\n")) }
      for want in wants { data.append(PktLine.encode("want \(want.hex)\n")) }
      for have in haves { data.append(PktLine.encode("have \(have.hex)\n")) }
      data.append(PktLine.encode("done\n"))
      data.append(PktLine.flushPacket)
      body = data
    } else {
      let offered = ["side-band-64k", "ofs-delta", "include-tag", "no-progress"].filter {
        advertisement.supports($0) && ($0 != "no-progress" || progress == nil)
      }
      var data = Data()
      for (number, want) in wants.enumerated() {
        let capabilities = number == 0 ? " " + (offered + ["agent=\(SmartHTTP.agent)"]).joined(separator: " ") : ""
        data.append(PktLine.encode("want \(want.hex)\(capabilities)\n"))
      }
      data.append(PktLine.flushPacket)
      for have in haves { data.append(PktLine.encode("have \(have.hex)\n")) }
      data.append(PktLine.encode("done\n"))
      body = data
    }
    var reader = PktLineReader(
      try await transport.post(Self.service, body: body, version2: advertisement.version2).makeAsyncIterator())
    let sideband = advertisement.version2 || advertisement.supports("side-band-64k")
    var sideband64 = SideBand(progress: progress)
    if advertisement.version2 {
      // Sections before `packfile` (acknowledgments, shallow-info, wanted-refs) don't matter after `done`.
      while let packet = try await reader.next() {
        if packet.text == "packfile" { break }
        if case .responseEnd = packet { throw GitEngineError.network("The server sent no pack.") }
      }
    }
    while let packet = try await reader.next() {
      guard case .data(let bytes) = packet else {
        if packet == .flush, advertisement.version2 || sideband { break }
        continue
      }
      if !advertisement.version2, bytes.starts(with: Array("NAK".utf8)) || bytes.starts(with: Array("ACK".utf8)) {
        if !sideband {
          // The pack follows as raw bytes.
          while let chunk = try await reader.nextChunk() { try indexer.append(chunk) }
          break
        }
        continue
      }
      if let data = try sideband64.handle(bytes) { try indexer.append(data) }
    }
    sideband64.flush()
  }
}

/// Splits side-band-64k packets: band 1 carries data, 2 progress text and 3 a fatal error.
struct SideBand {
  let progress: (@Sendable (String) -> Void)?
  private var partial = ""

  init(progress: (@Sendable (String) -> Void)?) {
    self.progress = progress
  }

  /// The data of a band-1 packet, or `nil` after passing progress on.
  mutating func handle(_ packet: [UInt8]) throws -> ArraySlice<UInt8>? {
    guard let band = packet.first else { return nil }
    let payload = packet.dropFirst()
    switch band {
    case 1:
      return payload
    case 2:
      // Progress lines end in `\r` (updated in place) or `\n`.
      partial += String(decoding: payload, as: UTF8.self)
      while let end = partial.firstIndex(where: { $0 == "\r" || $0 == "\n" || $0 == "\r\n" }) {
        let line = partial[..<end].trimmingCharacters(in: .whitespaces)
        partial = String(partial[partial.index(after: end)...])
        if !line.isEmpty { progress?(line.hasPrefix("remote: ") ? String(line.dropFirst(8)) : line) }
      }
      return nil
    case 3:
      let message = String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      throw GitEngineError.network("The server stopped: \(message)")
    default:
      return nil
    }
  }

  mutating func flush() {
    let line = partial.trimmingCharacters(in: .whitespacesAndNewlines)
    if !line.isEmpty { progress?(line) }
    partial = ""
  }
}
