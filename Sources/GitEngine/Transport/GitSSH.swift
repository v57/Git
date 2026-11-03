import Foundation

/// A remote reached over SSH: `git@github.com:owner/repo.git` or `ssh://git@github.com:22/owner/repo.git`.
public struct GitSSHAddress: Sendable, Hashable {
  /// The login, nil when the address names none.
  public var user: String?
  public var host: String
  public var port: Int?
  /// The repository's path as the server's git takes it: from the login's home when it doesn't start with `/`.
  public var path: String

  public init?(_ remote: String) {
    let text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    var address: Substring
    var path: Substring
    if let scheme = text.range(of: "://") {
      guard ["ssh", "git+ssh", "ssh+git"].contains(text[..<scheme.lowerBound].lowercased()) else { return nil }
      let rest = text[scheme.upperBound...]
      guard let slash = rest.firstIndex(of: "/") else { return nil }
      address = rest[..<slash]
      path = rest[slash...]
      // git's `ssh://host/~/repo`: from the login's home.
      if path.hasPrefix("/~") { path = path.dropFirst() }
      if let at = address.lastIndex(of: "@") {
        user = String(address[..<at])
        address = address[address.index(after: at)...]
      }
      if let colon = address.lastIndex(of: ":"), !address.hasSuffix("]") {
        guard let number = Int(address[address.index(after: colon)...]), (1...65535).contains(number) else { return nil }
        port = number
        address = address[..<colon]
      }
    } else {
      // `helper::address` runs a helper (`ext::sh -c …`), it's no host.
      if let helper = text.range(of: "::"), !text[..<helper.lowerBound].contains(where: { !($0.isLetter || $0.isNumber || "+.-".contains($0)) }) {
        return nil
      }
      // scp's `[user@]host:path`, which git takes for a local path when a slash comes before the colon.
      let start = text.firstIndex(of: "]") ?? text.startIndex
      guard let colon = text[start...].firstIndex(of: ":"), !text[..<colon].contains("/") else { return nil }
      address = text[..<colon]
      path = text[text.index(after: colon)...]
      if let at = address.lastIndex(of: "@") {
        user = String(address[..<at])
        address = address[address.index(after: at)...]
      }
    }
    if address.hasPrefix("["), address.hasSuffix("]") { address = address.dropFirst().dropLast() }
    guard !address.isEmpty, !path.isEmpty, !address.hasPrefix("-"), !address.contains(where: \.isWhitespace),
      user?.isEmpty != true
    else { return nil }
    host = String(address)
    self.path = String(path)
  }

  /// The command a server runs for `service`, as git sends it: the path in single quotes.
  func command(_ service: String) -> String {
    let quoted = path.replacingOccurrences(of: "'", with: "'\\''")
    return "\(service) '\(quoted)'"
  }
}

/// A command running on an SSH server: `git-upload-pack` or `git-receive-pack`, talking over its input and output.
public protocol GitSSHChannel: Sendable {
  /// The next piece of the command's output, nil once there's no more.
  func read() async throws -> Data?
  /// Queues `data` for the command's input.
  func write(_ data: Data)
  /// Closes the command's input once what's queued has gone out.
  func finishWriting()
  /// What it printed on standard error and how it ended, once it ended; nil when it ended without saying.
  func finished() async throws -> (errorOutput: String, status: Int32?)
  /// Hangs up.
  func close()
}

/// How GitEngine reaches SSH remotes. It knows git's protocol, not SSH: the app logs in, with its own key and host key
/// check, and hands over the command's channel (as `GitCredentials` hands over tokens for HTTPS).
public enum GitSSH {
  public typealias Connector = @Sendable (_ address: GitSSHAddress, _ command: String) async throws -> any GitSSHChannel

  private static let lock = NSLock()
  nonisolated(unsafe) private static var connector: Connector?
  /// A connector for one task and what it starts, for tests running side by side.
  @TaskLocal static var scoped: Connector?

  /// Sets how SSH remotes are reached. Without one they're refused.
  public static func setConnector(_ connector: Connector?) {
    lock.withLock { self.connector = connector }
  }

  static var current: Connector? { scoped ?? lock.withLock { connector } }
}

/// A service over SSH: one connection for the whole conversation, which is why it speaks protocol v0 (asking for v2
/// takes an environment variable most servers' `AcceptEnv` drop).
final class GitSSHTransport: ServiceTransport, @unchecked Sendable {
  private let channel: any GitSSHChannel
  private let bytes: ChannelBytes
  private let lock = NSLock()
  private var hasExchanged = false

  private init(channel: any GitSSHChannel, host: String) {
    self.channel = channel
    bytes = ChannelBytes(channel: channel, host: host)
  }

  /// Starts `service` on the server and reads what it advertises.
  static func discover(_ address: GitSSHAddress, service: String) async throws -> (GitSSHTransport, Data) {
    guard let connector = GitSSH.current else {
      throw GitEngineError.unsupported("SSH remotes don't work here yet. Use the repository's HTTPS address.")
    }
    let channel = try await connector(address, address.command(service))
    let transport = GitSSHTransport(channel: channel, host: address.host)
    do {
      // Up to the flush: what follows answers what we send.
      var reader = PktLineReader(ServerBytes(channel: transport.bytes))
      var advertisement = Data()
      while true {
        guard let packet = try await reader.next() else {
          throw GitEngineError.network("\(address.host) ended the connection before listing its branches.")
        }
        guard case .data(let line) = packet else { break }
        advertisement.append(PktLine.encode(line))
      }
      advertisement.append(PktLine.flushPacket)
      transport.bytes.hasAdvertised = true
      return (transport, advertisement)
    } catch {
      channel.close()
      throw error
    }
  }

  func exchange(_ service: String, body: Data, version2: Bool) async throws -> ServerBytes {
    lock.withLock { hasExchanged = true }
    channel.write(body)
    return ServerBytes(channel: bytes)
  }

  func close() {
    // A flush instead of a request ends the service without an error on the server's side.
    if !lock.withLock({ hasExchanged }) { channel.write(PktLine.flushPacket) }
    channel.finishWriting()
    // Lets what's queued go out before the hang-up.
    Task { [channel] in
      _ = try? await channel.finished()
      channel.close()
    }
  }
}

/// A channel's output one byte at a time. It's a class because the reader of the advertisement and the reader of the
/// answer share it, and at the end it tells why a command that failed did.
final class ChannelBytes: @unchecked Sendable {
  private let channel: any GitSSHChannel
  private let host: String
  private var chunk = Data()
  private var position = 0
  private var ended = false
  /// The service got as far as listing what it has. A command that fails before that never let this login in: a
  /// repository host says so that way (`Repository not found`, `Permission denied`).
  var hasAdvertised = false

  init(channel: any GitSSHChannel, host: String) {
    self.channel = channel
    self.host = host
  }

  func next() async throws -> UInt8? {
    while position >= chunk.count {
      if ended { return nil }
      if let data = try await channel.read() {
        chunk = data.startIndex == 0 ? data : Data(data)
        position = 0
      } else {
        ended = true
        chunk = Data()
        position = 0
        try await checkOutcome()
        return nil
      }
    }
    defer { position += 1 }
    return chunk[position]
  }

  /// The server's words when the command failed: the login's shell or the repository host says what's wrong on
  /// standard error (`Repository not found`, `command not found`).
  private func checkOutcome() async throws {
    let outcome = try await channel.finished()
    guard let status = outcome.status, status != 0 else { return }
    let message = outcome.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    throw GitEngineError(
      hasAdvertised ? .network : .authentication,
      message.isEmpty ? "\(host) stopped with status \(status)." : "\(host): \(message)")
  }
}
