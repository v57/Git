import Foundation

/// Why a `LocalRepository` operation failed, in words the app can show as they are.
public struct GitEngineError: Error, Sendable, Hashable, LocalizedError, CustomStringConvertible {
  public enum Kind: Sendable, Hashable {
    /// The folder has no `.git` directory.
    case notARepository
    /// The repository's files are damaged or use a format the engine doesn't read.
    case corrupt
    /// A name, revision or object that doesn't exist.
    case notFound
    /// The operation would lose or overwrite work, or isn't possible in the repository's state.
    case refused
    /// Another operation holds a lock file.
    case locked
    /// The server wants credentials, or refused the ones it got.
    case authentication
    /// The network or the server failed.
    case network
    /// A file couldn't be read or written.
    case fileSystem
  }

  public var kind: Kind
  public var message: String

  public init(_ kind: Kind, _ message: String) {
    self.kind = kind
    self.message = message
  }

  public var errorDescription: String? { message }
  public var description: String { message }

  static func corrupt(_ message: String) -> GitEngineError { GitEngineError(.corrupt, message) }
  static func refused(_ message: String) -> GitEngineError { GitEngineError(.refused, message) }
  static func notFound(_ message: String) -> GitEngineError { GitEngineError(.notFound, message) }
  static func network(_ message: String) -> GitEngineError { GitEngineError(.network, message) }

  static func missingObject(_ id: ObjectID) -> GitEngineError {
    .corrupt("The repository is missing object \(id.hex).")
  }

  /// A file-system error with the path it concerns.
  static func file(_ error: any Error, _ path: String) -> GitEngineError {
    if let error = error as? GitEngineError { return error }
    return GitEngineError(.fileSystem, "Couldn't access \(path): \(error.localizedDescription)")
  }
}
