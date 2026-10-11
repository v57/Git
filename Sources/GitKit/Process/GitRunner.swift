import Foundation

/// The output of one git run.
public struct GitResult: Sendable {
  public var stdout: Data
  public var stderr: Data
  public var exitCode: Int32

  /// stdout decoded as UTF-8 (invalid bytes replaced).
  public var output: String { String(decoding: stdout, as: UTF8.self) }
  public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs git with an argument vector (never through a shell).
///
/// stdout and stderr are read concurrently and kept apart, stdin is `/dev/null` unless input is
/// given, and cancelling the calling task terminates git. Credential prompts are disabled, so a
/// missing credential fails with git's message instead of hanging.
public struct GitRunner: Sendable {
  /// Settings passed as `-c` to every call: unquoted UTF-8 paths and no color codes.
  static let globalConfig = ["-c", "core.quotepath=false", "-c", "color.ui=never"]

  public var extraEnvironment: [String: String]

  public init(extraEnvironment: [String: String] = [:]) {
    self.extraEnvironment = extraEnvironment
  }

  /// Runs `git <arguments>` in `directory`.
  /// - Parameters:
  ///   - input: written to git's stdin, then closed.
  ///   - allowedExitCodes: exit codes that count as success (`diff --no-index` exits 1).
  ///   - progress: receives stderr lines as they arrive (split on `\r` and `\n`), for
  ///     `--progress` output.
  @discardableResult
  public func run(
    _ arguments: [String], in directory: URL?, input: Data? = nil,
    allowedExitCodes: Set<Int32> = [0], environment: [String: String] = [:],
    progress: (@Sendable (String) -> Void)? = nil
  ) async throws -> GitResult {
    guard let executable = GitExecutable.current else {
      throw GitError(
        arguments: arguments,
        message: "git was not found. Install the Command Line Tools (xcode-select --install) "
          + "or Homebrew git, or choose a git binary in Settings.")
    }
    let fullArguments = Self.globalConfig + arguments
    let process = Process()
    process.executableURL = executable
    process.arguments = fullArguments
    if let directory { process.currentDirectoryURL = directory }
    process.environment = Self.environment(merging: extraEnvironment.merging(environment) { $1 })

    let stdout = Pipe()
    let stderr = Pipe()
    let stdin = input == nil ? nil : Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = stdin ?? FileHandle.nullDevice

    let box = ProcessBox(process)
    let result: GitResult = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          let exited = DispatchSemaphore(value: 0)
          process.terminationHandler = { _ in exited.signal() }
          do {
            try process.run()
          } catch {
            continuation.resume(
              throwing: GitError(arguments: fullArguments, message: error.localizedDescription))
            return
          }
          if box.cancelled { process.terminate() }

          let group = DispatchGroup()
          let out = DataBox()
          let err = DataBox()
          group.enter()
          DispatchQueue.global(qos: .userInitiated).async {
            out.data = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
          }
          group.enter()
          DispatchQueue.global(qos: .userInitiated).async {
            err.data = Self.readAll(stderr.fileHandleForReading, progress: progress)
            group.leave()
          }
          if let stdin, let input {
            DispatchQueue.global(qos: .userInitiated).async {
              // git may exit before reading everything (e.g. on an error); ignore EPIPE.
              try? stdin.fileHandleForWriting.write(contentsOf: input)
              try? stdin.fileHandleForWriting.close()
            }
          }
          group.wait()
          exited.wait()
          continuation.resume(
            returning: GitResult(
              stdout: out.data, stderr: err.data, exitCode: process.terminationStatus))
        }
      }
    } onCancel: {
      box.cancel()
    }

    try Task.checkCancellation()
    guard allowedExitCodes.contains(result.exitCode) else {
      var message = result.errorOutput
      if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { message = result.output }
      throw GitError(arguments: fullArguments, exitCode: result.exitCode, message: message)
    }
    return result
  }

  /// Reads a pipe to EOF, reporting each `\r`/`\n`-terminated line to `progress`.
  private static func readAll(_ handle: FileHandle, progress: (@Sendable (String) -> Void)?)
    -> Data
  {
    guard let progress else { return handle.readDataToEndOfFile() }
    var all = Data()
    var pending = Data()
    while true {
      let chunk = handle.availableData
      if chunk.isEmpty { break }
      all.append(chunk)
      pending.append(chunk)
      while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
        let line = String(decoding: pending[pending.startIndex..<index], as: UTF8.self)
        pending.removeSubrange(pending.startIndex...index)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { progress(trimmed) }
      }
    }
    if !pending.isEmpty { progress(String(decoding: pending, as: UTF8.self)) }
    return all
  }

  /// The app's environment plus a PATH that finds Homebrew tools (credential helpers, gpg, hooks)
  /// even when the app was opened from Finder, and no interactive prompts.
  static func environment(merging extra: [String: String]) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let prefix = ["/opt/homebrew/bin", "/usr/local/bin"].filter { !path.contains($0) }
    env["PATH"] = (prefix + [path]).joined(separator: ":")
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["LC_ALL"] = "C"
    env["LANG"] = "C"
    // Never open an editor: callers pass messages explicitly.
    env["GIT_EDITOR"] = "true"
    env.removeValue(forKey: "GIT_DIR")
    env.removeValue(forKey: "GIT_WORK_TREE")
    env.removeValue(forKey: "GIT_INDEX_FILE")
    env.merge(extra) { $1 }
    return env
  }
}

private final class DataBox: @unchecked Sendable {
  var data = Data()
}

/// Lets the cancellation handler terminate a process that may not have started yet.
private final class ProcessBox: @unchecked Sendable {
  private let lock = NSLock()
  private let process: Process
  private var _cancelled = false

  init(_ process: Process) { self.process = process }

  var cancelled: Bool { lock.withLock { _cancelled } }

  func cancel() {
    lock.withLock {
      _cancelled = true
      if process.isRunning { process.terminate() }
    }
  }
}
