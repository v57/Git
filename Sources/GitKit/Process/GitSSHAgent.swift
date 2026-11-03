import Foundation
import os

#if os(macOS)
  import Darwin
#endif

/// Lets git's `ssh` sign in with a key it can't read, like the vault's Secure Enclave key: while a network command
/// runs, an SSH agent lives in this process on a socket of its own, and the command gets it as `SSH_AUTH_SOCK`.
///
/// The app's key comes first, then the keys of the agent the user already has, which everything else goes on to, so
/// logins that worked before still do. Only this process's descendants get an answer, and only logins are signed: a
/// repository's git can't use the key for anything else, and nothing can once the command has ended.
public enum GitSSHAgent {
  /// A key the agent signs with.
  public struct Identity: Sendable {
    /// The public key in SSH wire format.
    public var publicKeyBlob: Data
    public var comment: String
    /// The signature's body for `data`, without its algorithm's name.
    public var sign: @Sendable (Data) throws -> Data

    public init(publicKeyBlob: Data, comment: String, sign: @escaping @Sendable (Data) throws -> Data) {
      self.publicKeyBlob = publicKeyBlob
      self.comment = comment
      self.sign = sign
    }
  }

  private static let provider = OSAllocatedUnfairLock<(@Sendable () throws -> Identity)?>(initialState: nil)

  /// Sets where the key comes from, asked for when `ssh` wants it. Without one git's `ssh` runs as it always did.
  public static func setIdentity(_ identity: (@Sendable () throws -> Identity)?) {
    provider.withLock { $0 = identity }
  }

  /// Runs `body` with the environment that points `ssh` at the agent, for as long as it runs. It gets nothing to add
  /// when there's no key, or when git runs on another machine (`isLocal` false) and couldn't reach the socket.
  static func serving<Result: Sendable>(
    isLocal: Bool, _ body: @Sendable ([String: String]) async throws -> Result
  ) async throws -> Result {
    #if os(macOS)
      guard isLocal, let provider = provider.withLock({ $0 }), let server = try? AgentServer(identity: provider) else {
        return try await body([:])
      }
      defer { server.stop() }
      return try await body(["SSH_AUTH_SOCK": server.socketPath])
    #else
      return try await body([:])
    #endif
  }
}

#if os(macOS)
  /// One listening socket in a private folder, and a thread's worth of work for each connection `ssh` makes.
  private final class AgentServer: @unchecked Sendable {
    let socketPath: String
    private let folder: String
    private let listener: Int32
    private let source: any DispatchSourceRead
    private let identity: @Sendable () throws -> GitSSHAgent.Identity
    /// The agent the user already has.
    private let upstream = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]

    init(identity: @escaping @Sendable () throws -> GitSSHAgent.Identity) throws {
      self.identity = identity
      var template = Array((NSTemporaryDirectory() + "git-ssh-XXXXXXXX").utf8CString)
      // mkdtemp makes it readable by this user only.
      guard mkdtemp(&template) != nil else { throw AgentError.socket }
      folder = String(cString: template)
      socketPath = folder + "/agent"
      let listener = socket(AF_UNIX, SOCK_STREAM, 0)
      guard listener >= 0, Self.withAddress(socketPath, { bind(listener, $0, $1) }) == 0, Darwin.listen(listener, 8) == 0
      else {
        if listener >= 0 { close(listener) }
        try? FileManager.default.removeItem(atPath: folder)
        throw AgentError.socket
      }
      self.listener = listener
      source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .global(qos: .userInitiated))
      source.setEventHandler { [self] in accept() }
      source.setCancelHandler { [folder] in
        close(listener)
        try? FileManager.default.removeItem(atPath: folder)
      }
      source.resume()
    }

    func stop() {
      source.cancel()
    }

    private func accept() {
      let client = Darwin.accept(listener, nil, nil)
      guard client >= 0 else { return }
      Self.configure(client)
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        defer { close(client) }
        guard Self.isDescendant(of: client) else { return }
        serve(client)
      }
    }

    private func serve(_ client: Int32) {
      var upstreamSocket: Int32?
      defer { if let upstreamSocket { close(upstreamSocket) } }
      /// What the user's agent answers, connecting to it the first time it's needed.
      func askUpstream(_ message: [UInt8]) -> [UInt8]? {
        if upstreamSocket == nil, let upstream {
          let fd = socket(AF_UNIX, SOCK_STREAM, 0)
          if fd >= 0, Self.withAddress(upstream, { Darwin.connect(fd, $0, $1) }) == 0 {
            Self.configure(fd)
            upstreamSocket = fd
          } else if fd >= 0 {
            close(fd)
          }
        }
        guard let upstreamSocket, Self.write(message, to: upstreamSocket) else { return nil }
        return Self.read(from: upstreamSocket)
      }
      while let message = Self.read(from: client), let type = message.first {
        let answer: [UInt8]
        switch type {
        case AgentMessage.requestIdentities: answer = identities(upstream: askUpstream(message))
        case AgentMessage.signRequest: answer = sign(message) ?? askUpstream(message) ?? [AgentMessage.failure]
        default: answer = askUpstream(message) ?? [AgentMessage.failure]
        }
        guard Self.write(answer, to: client) else { return }
      }
    }

    /// The app's key, then the user's agent's.
    private func identities(upstream: [UInt8]?) -> [UInt8] {
      var count: UInt32 = 0
      var entries = Data()
      if let identity = try? identity() {
        entries.append(AgentMessage.string(identity.publicKeyBlob))
        entries.append(AgentMessage.string(Data(identity.comment.utf8)))
        count += 1
      }
      if let upstream, upstream.first == AgentMessage.identitiesAnswer, upstream.count >= 5 {
        count += upstream[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        entries.append(contentsOf: upstream[5...])
      }
      return [AgentMessage.identitiesAnswer] + AgentMessage.uint32(count) + entries
    }

    /// The signature when `message` asks for the app's key; nil when it's some other key's. Anything but a login's
    /// request gets a refusal.
    private func sign(_ message: [UInt8]) -> [UInt8]? {
      var reader = AgentMessage.Reader(bytes: message, position: 1)
      guard let blob = reader.string(), let data = reader.string(), let identity = try? identity(),
        Data(blob) == identity.publicKeyBlob
      else { return nil }
      guard AgentMessage.isLogin(data), let body = try? identity.sign(Data(data)) else { return [AgentMessage.failure] }
      var key = AgentMessage.Reader(bytes: blob, position: 0)
      guard let algorithm = key.string() else { return [AgentMessage.failure] }
      let signature = AgentMessage.string(Data(algorithm)) + AgentMessage.string(body)
      return [AgentMessage.signResponse] + AgentMessage.string(signature)
    }

    // MARK: Sockets

    private static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      let bytes = Array(path.utf8CString)
      let capacity = MemoryLayout.size(ofValue: address.sun_path)
      guard bytes.count <= capacity else { return -1 }
      withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
      }
    }

    /// No SIGPIPE when the other side has gone, and no waiting forever for one that stopped talking.
    private static func configure(_ socket: Int32) {
      var on: Int32 = 1
      setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      var timeout = timeval(tv_sec: 60, tv_usec: 0)
      setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Whether what connected was started by this process, however many steps away (git, then ssh).
    private static func isDescendant(of socket: Int32) -> Bool {
      var pid: pid_t = 0
      var length = socklen_t(MemoryLayout<pid_t>.size)
      guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return false }
      let own = getpid()
      while pid > 1 {
        if pid == own { return true }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        pid = info.kp_eproc.e_ppid
      }
      return false
    }

    /// One message: four bytes of length, then its type and contents.
    private static func read(from socket: Int32) -> [UInt8]? {
      guard let header = readExactly(4, from: socket) else { return nil }
      let length = header.reduce(0) { $0 << 8 | Int($1) }
      // OpenSSH's own limit.
      guard length > 0, length <= 256 * 1024 else { return nil }
      return readExactly(length, from: socket)
    }

    private static func readExactly(_ count: Int, from socket: Int32) -> [UInt8]? {
      var bytes = [UInt8](repeating: 0, count: count)
      var done = 0
      while done < count {
        let got = bytes.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress! + done, count - done) }
        if got < 0, errno == EINTR { continue }
        guard got > 0 else { return nil }
        done += got
      }
      return bytes
    }

    private static func write(_ message: [UInt8], to socket: Int32) -> Bool {
      let bytes = AgentMessage.uint32(UInt32(message.count)) + message
      var done = 0
      while done < bytes.count {
        let sent = bytes.withUnsafeBytes { Darwin.write(socket, $0.baseAddress! + done, bytes.count - done) }
        if sent < 0, errno == EINTR { continue }
        guard sent > 0 else { return false }
        done += sent
      }
      return true
    }

    private enum AgentError: Error {
      case socket
    }
  }
#endif

/// The SSH agent protocol's messages (draft-miller-ssh-agent).
enum AgentMessage {
  static let failure: UInt8 = 5
  static let requestIdentities: UInt8 = 11
  static let identitiesAnswer: UInt8 = 12
  static let signRequest: UInt8 = 13
  static let signResponse: UInt8 = 14
  /// SSH_MSG_USERAUTH_REQUEST.
  private static let loginRequest: UInt8 = 50

  static func uint32(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
  }

  static func string(_ data: Data) -> Data {
    Data(uint32(UInt32(data.count))) + data
  }

  /// Whether signing `data` signs in to a server: the session's id, then the login request (RFC 4252).
  static func isLogin(_ data: [UInt8]) -> Bool {
    var reader = Reader(bytes: data, position: 0)
    guard reader.string() != nil, reader.position < data.count else { return false }
    return data[reader.position] == loginRequest
  }

  struct Reader {
    let bytes: [UInt8]
    var position: Int

    /// A length, then that many bytes; nil past the end.
    mutating func string() -> [UInt8]? {
      guard position + 4 <= bytes.count else { return nil }
      let length = bytes[position..<position + 4].reduce(0) { $0 << 8 | Int($1) }
      position += 4
      guard length <= bytes.count - position else { return nil }
      defer { position += length }
      return Array(bytes[position..<position + length])
    }
  }
}
