import Foundation

#if os(Windows)
  import SwiftUIPortability
#endif

/// The output of one git run.
public struct GitResult: Sendable {
  public var stdout: Data
  public var stderr: Data
  public var exitCode: Int32
  /// git ran past its timeout and was terminated.
  var timedOut = false

  /// stdout decoded as UTF-8 (invalid bytes replaced).
  public var output: String { String(decoding: stdout, as: UTF8.self) }
  public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs git with an argument vector (never through a shell).
///
/// stdout and stderr are read concurrently and kept apart, stdin is `/dev/null` unless input is
/// given, and cancelling the calling task terminates git. Credential prompts are disabled, so a
/// missing credential fails with git's message instead of hanging.
///
/// A running git holds no thread: its output arrives through readability handlers and its exit
/// through the termination handler. At most `maxConcurrentProcesses` gits run at once and the
/// rest wait their turn, so a burst of refreshes across many repositories can't starve the app.
public struct GitRunner: Sendable {
  /// Settings passed as `-c` to every call: unquoted UTF-8 paths and no color codes.
  static let globalConfig = ["-c", "core.quotepath=false", "-c", "color.ui=never"]

  /// How many git processes may run at the same time, across the app.
  public static let maxConcurrentProcesses = 12
  private static let limiter = ProcessLimiter(limit: maxConcurrentProcesses)

  public var extraEnvironment: [String: String]

  public init(extraEnvironment: [String: String] = [:]) {
    self.extraEnvironment = extraEnvironment
  }

  /// Runs `git <arguments>` in `directory`.
  /// - Parameters:
  ///   - input: written to git's stdin, then closed.
  ///   - allowedExitCodes: exit codes that count as success (`diff --no-index` exits 1).
  ///   - timeout: terminates git after this long, for reads that must not hang the app.
  ///   - progress: receives stderr lines as they arrive (split on `\r` and `\n`), for
  ///     `--progress` output.
  @discardableResult
  public func run(
    _ arguments: [String], in directory: URL?, input: Data? = nil,
    allowedExitCodes: Set<Int32> = [0], environment: [String: String] = [:],
    timeout: Duration? = nil, progress: (@Sendable (String) -> Void)? = nil
  ) async throws -> GitResult {
    guard let executable = GitExecutable.current else {
      throw GitError(
        arguments: arguments,
        message: "git was not found. Install the Command Line Tools (xcode-select --install) "
          + "or Homebrew git, or choose a git binary in Settings.")
    }
    let fullArguments = Self.globalConfig + arguments

    await Self.limiter.acquire()
    let outcome = await Result {
      try Task.checkCancellation()
      return try await launch(
        executable, arguments: fullArguments, in: directory, input: input,
        environment: environment, timeout: timeout, progress: progress)
    }
    await Self.limiter.release()
    let result = try outcome.get()

    try Task.checkCancellation()
    if result.timedOut, let timeout {
      throw GitError(
        arguments: fullArguments, exitCode: result.exitCode,
        message: "git didn't finish within \(timeout.components.seconds) seconds and was stopped.")
    }
    guard allowedExitCodes.contains(result.exitCode) else {
      var message = result.errorOutput
      if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { message = result.output }
      throw GitError(arguments: fullArguments, exitCode: result.exitCode, message: message)
    }
    return result
  }

  #if os(Windows)
    /// git as a `ChildProcess`: on Windows a `Process` child inherits every handle the app can pass on (other gits'
    /// pipes, files being replaced), so gits running side by side kept each other's output open and blocked writes.
    private func launch(
      _ executable: URL, arguments: [String], in directory: URL?, input: Data?,
      environment: [String: String], timeout: Duration?, progress: (@Sendable (String) -> Void)?
    ) async throws -> GitResult {
      let state = RunState(progress: progress)
      let box = ChildBox()
      let timer = timeout.map { timeout in
        Task {
          try await Task.sleep(for: timeout)
          state.markTimedOut()
          box.cancel()
        }
      }
      defer { timer?.cancel() }
      let environment = Self.environment(merging: extraEnvironment.merging(environment) { $1 })

      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          state.start(continuation)
          let child: ChildProcess
          do {
            child = try ChildProcess(
              executable: executable, arguments: arguments, directory: directory, environment: environment,
              input: input != nil)
          } catch {
            state.fail(GitError(arguments: arguments, message: error.localizedDescription))
            return
          }
          box.set(child)
          Thread.detachNewThread {
            child.read(.output) { state.append($0, to: .stdout) }
            state.close(.stdout)
          }
          Thread.detachNewThread {
            child.read(.error) { state.append($0, to: .stderr) }
            state.close(.stderr)
          }
          if let input {
            DispatchQueue.global(qos: .userInitiated).async {
              child.write(input)
              child.closeInput()
            }
          }
          Thread.detachNewThread { state.exit(child.waitUntilExit()) }
        }
      } onCancel: {
        box.cancel()
      }
    }
  #else
    private func launch(
      _ executable: URL, arguments: [String], in directory: URL?, input: Data?,
      environment: [String: String], timeout: Duration?, progress: (@Sendable (String) -> Void)?
    ) async throws -> GitResult {
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      if let directory { process.currentDirectoryURL = directory }
      process.environment = Self.environment(merging: extraEnvironment.merging(environment) { $1 })

      let stdout = Pipe()
      let stderr = Pipe()
      let stdin = input == nil ? nil : Pipe()
      process.standardOutput = stdout
      process.standardError = stderr
      process.standardInput = stdin ?? FileHandle.nullDevice

      let state = RunState(progress: progress)
      let box = ProcessBox(process)
      let timer = timeout.map { timeout in
        Task {
          try await Task.sleep(for: timeout)
          state.markTimedOut()
          box.cancel()
        }
      }
      defer { timer?.cancel() }

      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          state.start(continuation)
          for (pipe, stream) in [(stdout, RunState.Stream.stdout), (stderr, .stderr)] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
              let data = handle.availableData
              if data.isEmpty {
                handle.readabilityHandler = nil
                state.close(stream)
              } else {
                state.append(data, to: stream)
              }
            }
          }
          process.terminationHandler = { process in state.exit(process.terminationStatus) }
          do {
            try process.run()
          } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            state.fail(GitError(arguments: arguments, message: error.localizedDescription))
            return
          }
          if box.cancelled { process.terminate() }
          if let stdin, let input {
            DispatchQueue.global(qos: .userInitiated).async {
              // git may exit before reading everything (e.g. on an error); ignore EPIPE.
              try? stdin.fileHandleForWriting.write(contentsOf: input)
              try? stdin.fileHandleForWriting.close()
            }
          }
        }
      } onCancel: {
        box.cancel()
      }
    }
  #endif

  /// The app's environment plus a PATH that finds Homebrew tools (credential helpers, gpg, hooks)
  /// even when the app was opened from Finder, and no interactive prompts.
  static func environment(merging extra: [String: String]) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    #if !os(Windows)
      let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
      let prefix = ["/opt/homebrew/bin", "/usr/local/bin"].filter { !path.contains($0) }
      env["PATH"] = (prefix + [path]).joined(separator: ":")
    #endif
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

/// One git run's output. Resumes the caller once git exited and both pipes reached EOF, in
/// whichever order those happen.
private final class RunState: @unchecked Sendable {
  enum Stream { case stdout, stderr }

  private let lock = NSLock()
  private let progress: (@Sendable (String) -> Void)?
  private var continuation: CheckedContinuation<GitResult, any Error>?
  private var stdout = Data()
  private var stderr = Data()
  /// stderr not yet reported to `progress` because its line hasn't ended.
  private var pendingLine = Data()
  private var openStreams = 2
  private var exitCode: Int32?
  private var timedOut = false

  init(progress: (@Sendable (String) -> Void)?) {
    self.progress = progress
  }

  func start(_ continuation: CheckedContinuation<GitResult, any Error>) {
    lock.withLock { self.continuation = continuation }
  }

  func append(_ data: Data, to stream: Stream) {
    let lines: [String] = lock.withLock {
      switch stream {
      case .stdout:
        stdout.append(data)
        return []
      case .stderr:
        stderr.append(data)
        guard progress != nil else { return [] }
        pendingLine.append(data)
        var lines: [String] = []
        while let index = pendingLine.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
          let line = String(decoding: pendingLine[pendingLine.startIndex..<index], as: UTF8.self)
          pendingLine.removeSubrange(pendingLine.startIndex...index)
          let trimmed = line.trimmingCharacters(in: .whitespaces)
          if !trimmed.isEmpty { lines.append(trimmed) }
        }
        return lines
      }
    }
    for line in lines { progress?(line) }
  }

  func close(_ stream: Stream) {
    let last: String? = lock.withLock {
      openStreams -= 1
      guard stream == .stderr, progress != nil, !pendingLine.isEmpty else { return nil }
      defer { pendingLine = Data() }
      return String(decoding: pendingLine, as: UTF8.self)
    }
    if let last { progress?(last) }
    resumeIfDone()
  }

  func exit(_ status: Int32) {
    lock.withLock { exitCode = status }
    resumeIfDone()
  }

  func markTimedOut() {
    lock.withLock { timedOut = true }
  }

  func fail(_ error: any Error) {
    let continuation = lock.withLock { () -> CheckedContinuation<GitResult, any Error>? in
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.resume(throwing: error)
  }

  private func resumeIfDone() {
    let done = lock.withLock { () -> (CheckedContinuation<GitResult, any Error>, GitResult)? in
      guard openStreams == 0, let exitCode, let continuation else { return nil }
      self.continuation = nil
      let result = GitResult(stdout: stdout, stderr: stderr, exitCode: exitCode, timedOut: timedOut)
      return (continuation, result)
    }
    if let (continuation, result) = done { continuation.resume(returning: result) }
  }
}

/// Limits how many git processes run at once. Waiting callers suspend rather than block a thread.
private actor ProcessLimiter {
  private let limit: Int
  private var running = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    self.limit = limit
  }

  func acquire() async {
    guard running >= limit else {
      running += 1
      return
    }
    // `release` hands its slot straight to the first waiter, so `running` stays the same.
    await withCheckedContinuation { waiting.append($0) }
  }

  func release() {
    if waiting.isEmpty {
      running -= 1
    } else {
      waiting.removeFirst().resume()
    }
  }
}

/// Lets the cancellation handler terminate a process that may not have started yet.
#if os(Windows)
  /// The running git, terminated on cancellation (even one that hasn't started yet).
  private final class ChildBox: @unchecked Sendable {
    private let lock = NSLock()
    private var child: ChildProcess?
    private var cancelled = false

    func set(_ child: ChildProcess) {
      let cancelled = lock.withLock {
        self.child = child
        return self.cancelled
      }
      if cancelled { child.terminate() }
    }

    func cancel() {
      let child = lock.withLock {
        cancelled = true
        return self.child
      }
      child?.terminate()
    }
  }
#endif

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
