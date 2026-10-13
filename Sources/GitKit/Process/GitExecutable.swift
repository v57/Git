import Foundation
import os

/// Finds the git binary the library runs.
///
/// Order: a custom path (set by the app's settings), Homebrew (`/opt/homebrew`, `/usr/local`), then
/// `/usr/bin/git`. The `/usr/bin/git` shim is only used when a developer directory is selected;
/// without the Command Line Tools it pops the installer instead of running git.
public enum GitExecutable {
  private static let state = OSAllocatedUnfairLock<(custom: String?, cached: URL??)>(initialState: (nil, nil))

  /// A user-chosen git binary. `nil` or empty means automatic.
  public static var customPath: String? {
    get { state.withLock { $0.custom } }
    set {
      state.withLock {
        $0.custom = newValue?.isEmpty == true ? nil : newValue
        $0.cached = nil
      }
    }
  }

  /// The git binary to run, or `nil` when none is installed.
  public static var current: URL? {
    if let cached = state.withLock({ $0.cached }) { return cached }
    let found = locate(customPath: customPath)
    state.withLock { $0.cached = .some(found) }
    return found
  }

  public static let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]

  static func locate(customPath: String?) -> URL? {
    let fm = FileManager.default
    if let customPath, fm.isExecutableFile(atPath: customPath) {
      return URL(fileURLWithPath: customPath)
    }
    for path in candidates where fm.isExecutableFile(atPath: path) {
      if path == "/usr/bin/git", !hasDeveloperDirectory() { continue }
      return URL(fileURLWithPath: path)
    }
    return nil
  }

  /// `xcode-select -p` succeeds once Xcode or the Command Line Tools are installed.
  static func hasDeveloperDirectory() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  /// `git --version`, e.g. `git version 2.54.0`.
  public static func version() async -> String? {
    guard let result = try? await GitRunner().run(["--version"], in: nil) else { return nil }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
