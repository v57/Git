import Foundation
import GitEngine
import GitKit

/// What the screens do with a repository, wherever it is: GitKit's `Repository` running git on a Mac over SSH, or
/// GitEngine's `LocalRepository` for one on this device. Both speak GitKit's models.
nonisolated protocol GitBackend: Sendable {
  /// What it can do beyond the basics every backend has.
  var features: GitFeatures { get }
  func status() async throws -> WorkingTreeStatus
  /// Lines added and removed per changed file, keyed by `FileChange.id`.
  func lineCounts(_ status: WorkingTreeStatus) async -> [FileChange.ID: LineCounts]
  func log(skip: Int, limit: Int) async throws -> [Commit]
  func changedFiles(in commit: Commit) async throws -> [CommitFile]
  func diff(_ target: DiffTarget) async throws -> FileDiff?
  func contents(of path: String, at revision: FileRevision) async -> Data?
  func stage(_ changes: [FileChange]) async throws
  func unstage(_ changes: [FileChange]) async throws
  func stageAll() async throws
  func unstageAll() async throws
  func discard(_ changes: [FileChange]) async throws
  func stageLines(_ lines: Set<Int>, of diff: FileDiff) async throws
  func unstageLines(_ lines: Set<Int>, of diff: FileDiff) async throws
  func discardLines(_ lines: Set<Int>, of diff: FileDiff) async throws
  /// The new commit's id.
  func commit(message: String, amend: Bool) async throws -> String
  func lastCommitMessage() async throws -> String
  func branches() async throws -> [Branch]
  func switchTo(_ branch: Branch) async throws
  func createBranch(_ name: String) async throws
  func fetch(progress: @escaping @Sendable (String) -> Void) async throws
  func pull(progress: @escaping @Sendable (String) -> Void) async throws
  func push(progress: @escaping @Sendable (String) -> Void) async throws
}

struct GitFeatures: OptionSet, Sendable {
  let rawValue: Int
  /// Stage, unstage and discard single lines and hunks.
  static let lineStaging = GitFeatures(rawValue: 1 << 0)
  /// Amend the last commit.
  static let amend = GitFeatures(rawValue: 1 << 1)
}

enum BackendError: LocalizedError {
  case unsupported(String)

  var errorDescription: String? {
    switch self {
    case .unsupported(let what): "\(what) needs git on a Mac: open the repository on one of your devices."
    }
  }
}

// MARK: - On a Mac

/// GitKit's repository, its git running on another machine through `SSHGitTransport`.
nonisolated struct RemoteBackend: GitBackend {
  let repository: Repository

  var features: GitFeatures { [.lineStaging, .amend] }

  func status() async throws -> WorkingTreeStatus { try await repository.status() }

  func lineCounts(_ status: WorkingTreeStatus) async -> [FileChange.ID: LineCounts] {
    let untracked = status.unstaged.filter { $0.kind == .untracked }.map(\.path)
    guard let counts = try? await repository.lineCounts(untracked: untracked) else { return [:] }
    var result: [FileChange.ID: LineCounts] = [:]
    for change in status.staged { result[change.id] = counts.staged[change.path] }
    for change in status.unstaged { result[change.id] = counts.unstaged[change.path] }
    return result
  }

  func log(skip: Int, limit: Int) async throws -> [Commit] {
    try await repository.log(LogQuery(), skip: skip, limit: limit)
  }

  func changedFiles(in commit: Commit) async throws -> [CommitFile] { try await repository.changedFiles(in: commit) }
  func diff(_ target: DiffTarget) async throws -> FileDiff? { try await repository.diff(target) }
  func contents(of path: String, at revision: FileRevision) async -> Data? {
    await repository.contents(of: path, at: revision)
  }
  func stage(_ changes: [FileChange]) async throws { try await repository.stage(Self.paths(changes)) }
  func unstage(_ changes: [FileChange]) async throws { try await repository.unstage(Self.paths(changes)) }
  func stageAll() async throws { try await repository.stageAll() }
  func unstageAll() async throws { try await repository.unstageAll() }
  func discard(_ changes: [FileChange]) async throws {
    let staged = changes.filter { $0.area == .staged }
    if !staged.isEmpty { try await repository.discardStaged(staged) }
    let unstaged = changes.filter { $0.area != .staged }
    if !unstaged.isEmpty { try await repository.discard(unstaged) }
  }
  func stageLines(_ lines: Set<Int>, of diff: FileDiff) async throws { try await repository.stageLines(lines, of: diff) }
  func unstageLines(_ lines: Set<Int>, of diff: FileDiff) async throws {
    try await repository.unstageLines(lines, of: diff)
  }
  func discardLines(_ lines: Set<Int>, of diff: FileDiff) async throws {
    try await repository.discardLines(lines, of: diff)
  }
  func commit(message: String, amend: Bool) async throws -> String {
    try await repository.commit(message: message, amend: amend)
  }
  func lastCommitMessage() async throws -> String { try await repository.lastCommitMessage() }
  func branches() async throws -> [Branch] { try await repository.branches() }
  func switchTo(_ branch: Branch) async throws { try await repository.switchTo(branch) }
  func createBranch(_ name: String) async throws { try await repository.createBranch(name) }
  func fetch(progress: @escaping @Sendable (String) -> Void) async throws { try await repository.fetch(progress: progress) }
  func pull(progress: @escaping @Sendable (String) -> Void) async throws { try await repository.pull(progress: progress) }
  func push(progress: @escaping @Sendable (String) -> Void) async throws { try await repository.push(progress: progress) }

  /// A renamed file's old path too, so both sides of the rename move together.
  private static func paths(_ changes: [FileChange]) -> [String] {
    Array(Set(changes.flatMap { [$0.path, $0.originalPath].compactMap { $0 } })).sorted()
  }
}

// MARK: - On this device

/// GitEngine's repository: git in Swift, for a repository in the app's folder. No line staging or amend.
nonisolated struct LocalBackend: GitBackend {
  let repository: LocalRepository
  /// Who commits, when the repository's config doesn't say.
  let author: @Sendable () -> GitSignature?

  var features: GitFeatures { [] }

  func status() async throws -> WorkingTreeStatus { try await repository.status() }

  func lineCounts(_ status: WorkingTreeStatus) async -> [FileChange.ID: LineCounts] {
    // Counting lines diffs every file: only for a handful of them.
    let changes = status.staged + status.unstaged
    guard changes.count <= 50 else { return [:] }
    var result: [FileChange.ID: LineCounts] = [:]
    for change in changes {
      let target: DiffTarget =
        change.area == .staged
        ? .staged(path: change.path, originalPath: change.originalPath)
        : .unstaged(path: change.path, untracked: change.kind == .untracked)
      guard let diff = try? await repository.diff(target) else { continue }
      result[change.id] =
        diff.isBinary ? LineCounts(added: nil, removed: nil) : LineCounts(added: diff.additions, removed: diff.deletions)
    }
    return result
  }

  func log(skip: Int, limit: Int) async throws -> [Commit] { try await repository.log(skip: skip, limit: limit) }
  func changedFiles(in commit: Commit) async throws -> [CommitFile] { try await repository.changedFiles(in: commit) }
  func diff(_ target: DiffTarget) async throws -> FileDiff? { try await repository.diff(target) }
  func contents(of path: String, at revision: FileRevision) async -> Data? {
    await repository.contents(of: path, at: revision)
  }
  func stage(_ changes: [FileChange]) async throws { try await repository.stage(Self.paths(changes)) }
  func unstage(_ changes: [FileChange]) async throws { try await repository.unstage(Self.paths(changes)) }
  func stageAll() async throws { try await repository.stageAll() }
  func unstageAll() async throws { try await repository.unstageAll() }
  func discard(_ changes: [FileChange]) async throws {
    let staged = changes.filter { $0.area == .staged }
    if !staged.isEmpty {
      try await repository.unstage(Self.paths(staged))
      let paths = Set(Self.paths(staged))
      try await repository.discard(try await repository.status().unstaged.filter { paths.contains($0.path) })
    }
    let unstaged = changes.filter { $0.area != .staged }
    if !unstaged.isEmpty { try await repository.discard(unstaged) }
  }
  func stageLines(_ lines: Set<Int>, of diff: FileDiff) async throws { throw BackendError.unsupported("Staging lines") }
  func unstageLines(_ lines: Set<Int>, of diff: FileDiff) async throws {
    throw BackendError.unsupported("Unstaging lines")
  }
  func discardLines(_ lines: Set<Int>, of diff: FileDiff) async throws {
    throw BackendError.unsupported("Discarding lines")
  }

  func commit(message: String, amend: Bool) async throws -> String {
    guard !amend else { throw BackendError.unsupported("Amending") }
    let name = repository.config("user.name")
    let email = repository.config("user.email")
    let signature: GitSignature
    if let name, let email {
      signature = GitSignature(name: name, email: email)
    } else if let fallback = author() {
      signature = GitSignature(name: name ?? fallback.name, email: email ?? fallback.email)
    } else {
      throw LocalRepositories.Problem.noAuthor
    }
    return try await repository.commit(message: message, author: signature)
  }

  func lastCommitMessage() async throws -> String {
    try await repository.log(limit: 1).first?.message ?? ""
  }
  func branches() async throws -> [Branch] { try await repository.branches() }
  func switchTo(_ branch: Branch) async throws { try await repository.switchTo(branch) }
  func createBranch(_ name: String) async throws { try await repository.createBranch(name) }
  func fetch(progress: @escaping @Sendable (String) -> Void) async throws { try await repository.fetch(progress: progress) }
  func pull(progress: @escaping @Sendable (String) -> Void) async throws { try await repository.pull(progress: progress) }
  func push(progress: @escaping @Sendable (String) -> Void) async throws { try await repository.push(progress: progress) }

  private static func paths(_ changes: [FileChange]) -> [String] {
    Array(Set(changes.flatMap { [$0.path, $0.originalPath].compactMap { $0 } })).sorted()
  }
}
