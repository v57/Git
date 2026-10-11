import Foundation

/// A failed git invocation, or a precondition the library checks before running git.
public struct GitError: Error, Sendable, LocalizedError, CustomStringConvertible {
  /// The arguments passed to git (without the executable).
  public var arguments: [String]
  /// The process exit code, or `nil` when git never ran.
  public var exitCode: Int32?
  /// git's stderr (or the reason git could not run), trimmed.
  public var message: String

  public init(arguments: [String] = [], exitCode: Int32? = nil, message: String) {
    self.arguments = arguments
    self.exitCode = exitCode
    self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The subcommand that failed, e.g. `push`.
  public var command: String {
    // Skip the `-c key=value` pairs the runner prepends.
    var index = 0
    while index < arguments.count, arguments[index] == "-c" { index += 2 }
    return index < arguments.count ? arguments[index] : "git"
  }

  public var errorDescription: String? { message.isEmpty ? "git \(command) failed" : message }
  public var description: String { "git \(command) (\(exitCode.map(String.init) ?? "-")): \(message)" }
}
