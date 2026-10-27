import Foundation
import GitKit

/// A git repository on this device, read and changed in Swift without a git binary (for iPhone and iPad). Methods
/// return GitKit's models, so views work the same for these and for `Repository`.
///
/// Each method opens the repository's files afresh, so the value is cheap and safe to share between tasks. Heavy
/// methods are `@concurrent` and run off the caller's actor.
public struct LocalRepository: Sendable, Hashable, Identifiable {
  /// The working tree (the folder holding `.git`).
  public let url: URL

  public var id: URL { url }
  public var name: String { url.lastPathComponent }

  /// Opens the repository at `url`; throws when `url/.git` isn't a repository folder.
  public init(url: URL) throws {
    self.url = url.standardizedFileURL
    _ = try GitContext(worktree: self.url)
  }

  private init(trusted url: URL) {
    self.url = url.standardizedFileURL
  }

  public static func isRepository(_ url: URL) -> Bool {
    (try? GitContext(worktree: url.standardizedFileURL)) != nil
  }

  func context() throws -> GitContext { try GitContext(worktree: url) }

  /// Creates an empty repository in `url` (made if needed), as `git init` does.
  public static func initialize(at url: URL, initialBranch: String = "main") throws -> LocalRepository {
    let url = url.standardizedFileURL
    let git = url.appendingPathComponent(".git", isDirectory: true)
    guard !FileManager.default.fileExists(atPath: git.path) else {
      throw GitEngineError.refused("\(url.lastPathComponent) is already a git repository.")
    }
    guard BranchName.isValid(initialBranch) else {
      throw GitEngineError.refused("“\(initialBranch)” isn't a valid branch name.")
    }
    do {
      for folder in ["objects/info", "objects/pack", "refs/heads", "refs/tags", "info"] {
        try FileManager.default.createDirectory(
          at: git.appendingPathComponent(folder), withIntermediateDirectories: true)
      }
      try Data("ref: refs/heads/\(initialBranch)\n".utf8).write(to: git.appendingPathComponent("HEAD"))
      try Data(
        "# git ls-files --others --exclude-from=.git/info/exclude\n# Lines that start with '#' are comments.\n".utf8
      ).write(to: git.appendingPathComponent("info/exclude"))
      try Data("Unnamed repository; edit this file 'description' to name the repository.\n".utf8)
        .write(to: git.appendingPathComponent("description"))
      var config = GitConfig(text: "")
      try config.set("core.repositoryformatversion", "0")
      try config.set("core.filemode", "true")
      try config.set("core.bare", "false")
      try config.set("core.logallrefupdates", "true")
      if isCaseInsensitive(git) {
        try config.set("core.ignorecase", "true")
        try config.set("core.precomposeunicode", "true")
      }
      try Data(config.text.utf8).write(to: git.appendingPathComponent("config"))
    } catch {
      throw GitEngineError.file(error, url.path)
    }
    return LocalRepository(trusted: url)
  }

  /// Whether the file system finds `config` as `CONFIG`, as git probes it.
  private static func isCaseInsensitive(_ git: URL) -> Bool {
    try? Data().write(to: git.appendingPathComponent("config"))
    return FileManager.default.fileExists(atPath: git.appendingPathComponent("CONFIG").path)
  }

  // MARK: Config

  /// A value from `.git/config`, e.g. `user.name`, `remote.origin.url` or `branch.main.merge`.
  public func config(_ key: String) -> String? {
    GitConfig(url: url.appendingPathComponent(".git/config")).value(key)
  }

  /// Sets a value in `.git/config`, or removes it with `nil`.
  public func setConfig(_ key: String, _ value: String?) throws {
    try context().updateConfig { try $0.set(key, value) }
  }
}

/// git's rules for ref names (`git check-ref-format --branch`), simplified.
enum BranchName {
  static func isValid(_ name: String) -> Bool {
    guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix("."),
      !name.hasSuffix(".lock"), !name.contains(".."), !name.contains("//"), !name.contains("@{"), name != "@",
      name != "HEAD"
    else { return false }
    let forbidden = Set(" ~^:?*[\\\u{7F}")
    if name.contains(where: { forbidden.contains($0) || ($0.asciiValue.map { $0 < 0x20 } ?? false) }) { return false }
    return !name.split(separator: "/").contains { $0.hasPrefix(".") || $0.hasSuffix(".lock") }
  }
}
