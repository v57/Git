import Foundation

/// git's way to replace a file atomically: write `<file>.lock` (created exclusively, so two writers can't both hold
/// it), then rename it over the file.
struct LockFile {
  let url: URL
  private let lockURL: URL
  private let descriptor: Int32

  /// Takes the lock, or throws when another operation holds it.
  init(_ url: URL) throws {
    self.url = url
    lockURL = url.appendingPathExtension("lock")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    descriptor = open(lockURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o666)
    guard descriptor >= 0 else {
      if errno == EEXIST {
        throw GitEngineError(
          .locked,
          "Another git operation is using \(url.lastPathComponent). If none is running, delete "
            + "\(lockURL.lastPathComponent) in the .git folder.")
      }
      throw GitEngineError(.fileSystem, "Couldn't lock \(url.lastPathComponent): \(String(cString: strerror(errno))).")
    }
  }

  /// Writes `data` and renames the lock over the file.
  func commit(_ data: Data) throws {
    let written = data.withUnsafeBytes { buffer -> Bool in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count <= 0 { return false }
        offset += count
      }
      return true
    }
    close(descriptor)
    guard written, rename(lockURL.path, url.path) == 0 else {
      unlink(lockURL.path)
      throw GitEngineError(.fileSystem, "Couldn't write \(url.lastPathComponent).")
    }
  }

  /// Gives the lock up without changing the file.
  func cancel() {
    close(descriptor)
    unlink(lockURL.path)
  }

  /// Takes the lock, writes and renames in one step.
  static func write(_ data: Data, to url: URL) throws {
    try LockFile(url).commit(data)
  }
}
