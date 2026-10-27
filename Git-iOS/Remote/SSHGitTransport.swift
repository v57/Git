import Foundation
import GitKit
import SSHKit

/// GitKit's git on another machine: every git call is a command on one SSH connection (`SSHConnection`, its own
/// channel each, so a refresh's calls run side by side), in the repository's folder there, and the working tree's
/// files are read and written with small shell commands on the same connection. The connection opens on first use
/// and again after it drops.
///
/// Commands run in the login's `$SHELL -c`, as `ssh host command` runs them, with Homebrew's folders put first on the
/// PATH (a non-interactive shell doesn't read the profile that adds them): the Mac's own git, config, hooks and
/// credentials apply.
nonisolated final class SSHGitTransport: GitTransport, @unchecked Sendable {
  let target: RemoteTarget
  private let login: @Sendable () async throws -> SSHServer
  private let onNewHostKey: @Sendable (String) -> Void
  private let lock = NSLock()
  private var connecting: Task<SSHConnection, Error>?

  init(
    target: RemoteTarget, login: @escaping @Sendable () async throws -> SSHServer,
    onNewHostKey: @escaping @Sendable (String) -> Void
  ) {
    self.target = target
    self.login = login
    self.onNewHostKey = onNewHostKey
  }

  /// The open connection, or a new one when there's none or it dropped. Callers arriving while one opens share it.
  func connection() async throws -> SSHConnection {
    let task = lock.withLock { () -> Task<SSHConnection, Error> in
      if let connecting { return connecting }
      let task = Task { [login, onNewHostKey] in
        let server = try await login()
        let connection = try await SSHConnection.connect(server: server, timeout: 15)
        if server.knownFingerprint == nil { onNewHostKey(connection.hostKeyFingerprint) }
        return connection
      }
      connecting = task
      return task
    }
    do {
      let connection = try await task.value
      if connection.isAlive { return connection }
      lock.withLock { if connecting == task { connecting = nil } }
      return try await self.connection()
    } catch {
      lock.withLock { if connecting == task { connecting = nil } }
      throw error
    }
  }

  func close() {
    let task = lock.withLock {
      defer { connecting = nil }
      return connecting
    }
    Task { try? await task?.value.close() }
  }

  /// Runs a shell script there.
  func shell(_ script: String, input: Data? = nil, onError: (@Sendable (Data) -> Void)? = nil) async throws
    -> SSHConnection.Output
  {
    let script = "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; export PATH; " + script
    return try await connection().run(script, input: input, onError: onError)
  }

  // MARK: GitTransport

  func run(
    _ arguments: [String], in directory: URL?, input: Data?, environment: [String: String],
    progress: (@Sendable (String) -> Void)?
  ) async throws -> GitResult {
    var script = environment.keys.sorted().map { "export \($0)=\(Self.quote(environment[$0]!)); " }.joined()
    if let directory { script += "cd \(Self.path(directory.path)) && " }
    script += "exec git " + arguments.map(Self.quote).joined(separator: " ")
    let lines = progress.map(LineSplitter.init)
    let output = try await shell(script, input: input, onError: lines.map { lines in { lines.append($0) } })
    lines?.finish()
    // A command ended by a signal reports no status: it failed.
    return GitResult(stdout: output.stdout, stderr: output.stderr, exitCode: output.status ?? 255)
  }

  func contents(of url: URL) async throws -> Data? {
    let path = Self.path(url.path)
    let output = try await shell("[ -e \(path) ] || exit 3; exec cat -- \(path)")
    if output.status == 3 { return nil }
    try Self.check(output, "read \(url.lastPathComponent)")
    return output.stdout
  }

  func write(_ data: Data, to url: URL) async throws {
    // `>` truncates the file in place, so it keeps its permissions.
    let output = try await shell("cat > \(Self.path(url.path))", input: data)
    try Self.check(output, "write \(url.lastPathComponent)")
  }

  func fileExists(at url: URL) async -> Bool {
    (try? await shell("[ -e \(Self.path(url.path)) ]"))?.status == 0
  }

  /// To the Trash on a Mac (named as Finder would, with a time when the name is taken), else removed.
  func discard(_ url: URL) async throws {
    let path = Self.path(url.path)
    let name = Self.quote(url.lastPathComponent)
    let script = """
      if [ -d "$HOME/.Trash" ]; then
        to="$HOME/.Trash/"\(name); [ -e "$to" ] && to="$to $(date +%H.%M.%S)"; exec mv -- \(path) "$to"
      else exec rm -rf -- \(path); fi
      """
    try Self.check(try await shell(script), "move \(url.lastPathComponent) to the Trash")
  }

  // MARK: Helpers

  private static func check(_ output: SSHConnection.Output, _ what: String) throws {
    guard output.status != 0 else { return }
    let message = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    throw RemoteError.failed("Couldn’t \(what)" + (message.isEmpty ? "." : ": \(message)"))
  }

  /// `'text'`, with single quotes inside escaped.
  static func quote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// A path for the shell there: quoted, with a leading `~` left to the shell (the login's home folder).
  static func path(_ path: String) -> String {
    if path == "~" { return "\"$HOME\"" }
    if path.hasPrefix("~/") { return "\"$HOME\"/" + quote(String(path.dropFirst(2))) }
    return quote(path)
  }

  enum RemoteError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
      switch self {
      case .failed(let message): message
      }
    }
  }
}

/// Standard error as progress lines: split on `\r` and `\n` as git's `--progress` output updates in place.
private nonisolated final class LineSplitter: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = Data()
  private let report: @Sendable (String) -> Void

  init(_ report: @escaping @Sendable (String) -> Void) {
    self.report = report
  }

  func append(_ data: Data) {
    let lines: [String] = lock.withLock {
      pending.append(data)
      var lines: [String] = []
      while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
        let line = String(decoding: pending[pending.startIndex..<index], as: UTF8.self)
        pending.removeSubrange(pending.startIndex...index)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { lines.append(trimmed) }
      }
      return lines
    }
    for line in lines { report(line) }
  }

  func finish() {
    let last = lock.withLock {
      defer { pending = Data() }
      return String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if !last.isEmpty { report(last) }
  }
}
