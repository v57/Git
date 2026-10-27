import Foundation
import GitEngine
import GitKit

/// The repositories on this device: the folders in the app's Documents (which the Files app shows as "Git"), each a
/// repository GitEngine reads and writes. Cloned and created here; the Files app can add more.
@MainActor @Observable final class LocalRepositories {
  static let shared = LocalRepositories()

  private(set) var repositories: [LocalRepository] = []

  /// Where they are: the app's Documents folder.
  let folder: URL

  init(folder: URL = LocalRepositories.defaultFolder) {
    self.folder = folder
    reload()
  }

  nonisolated static var defaultFolder: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  }

  /// Lists the folders that are repositories, by name.
  func reload() {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    repositories = names.filter { !$0.hasPrefix(".") }
      .map { folder.appendingPathComponent($0, isDirectory: true) }
      .filter(LocalRepository.isRepository)
      .compactMap { try? LocalRepository(url: $0) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// A folder name for `name` that isn't taken ("Atlas", then "Atlas 2").
  func freeName(_ name: String) -> String {
    let base = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
    var candidate = base.isEmpty ? "Repository" : base
    var number = 2
    while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
      candidate = "\(base) \(number)"
      number += 1
    }
    return candidate
  }

  /// Creates an empty repository on `main`.
  func create(named name: String) throws -> LocalRepository {
    let url = folder.appendingPathComponent(freeName(name), isDirectory: true)
    let repository = try LocalRepository.initialize(at: url)
    reload()
    return repository
  }

  /// Clones `remote` (HTTPS) into a folder named after it. A failed clone leaves no folder behind.
  func clone(_ remote: String, progress: @escaping @Sendable (String) -> Void) async throws -> LocalRepository {
    let url = folder.appendingPathComponent(freeName(Self.name(ofRemote: remote)), isDirectory: true)
    do {
      let repository = try await LocalRepository.clone(from: remote, to: url, progress: progress)
      reload()
      return repository
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  /// Deletes the repository's folder for good (its commits that were never pushed too).
  func delete(_ repository: LocalRepository) throws {
    try FileManager.default.removeItem(at: repository.url)
    reload()
  }

  /// "atlas" for `https://github.com/aiko/atlas.git`.
  static func name(ofRemote remote: String) -> String {
    var name = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    while name.hasSuffix("/") { name.removeLast() }
    name = String(name.split(separator: "/").last ?? "")
    if name.hasSuffix(".git") { name.removeLast(4) }
    return name.isEmpty ? "Repository" : name
  }

  /// A remote as the user typed it, made into an HTTPS URL GitEngine fetches from: `aiko/atlas` and
  /// `github.com/aiko/atlas` are GitHub's, `git@github.com:aiko/atlas.git` becomes HTTPS (GitEngine has no SSH).
  static func httpsURL(_ text: String) -> String? {
    var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if text.hasPrefix("git@"), let colon = text.firstIndex(of: ":") {
      let host = text[text.index(text.startIndex, offsetBy: 4)..<colon]
      text = "https://\(host)/\(text[text.index(after: colon)...])"
    } else if text.hasPrefix("http://") || text.hasPrefix("https://") {
      // As typed.
    } else if text.split(separator: "/").count == 2, !text.contains(".") || text.hasSuffix(".git") {
      text = "https://github.com/" + text
    } else {
      text = "https://" + text
    }
    guard let url = URL(string: text), url.host != nil else { return nil }
    return text
  }

  enum Problem: LocalizedError {
    case noAuthor

    var errorDescription: String? {
      switch self {
      case .noAuthor: "Set your name and email for commits in Settings first."
      }
    }
  }
}

/// Who commits in repositories on this device whose config doesn't name anyone: set in Settings.
enum CommitAuthor {
  static var name: String {
    get { UserDefaults.standard.string(forKey: "author.name") ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: "author.name") }
  }

  static var email: String {
    get { UserDefaults.standard.string(forKey: "author.email") ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: "author.email") }
  }

  nonisolated static var signature: GitSignature? {
    let defaults = UserDefaults.standard
    guard let name = defaults.string(forKey: "author.name"), !name.isEmpty,
      let email = defaults.string(forKey: "author.email"), !email.isEmpty
    else { return nil }
    return GitSignature(name: name, email: email)
  }
}
