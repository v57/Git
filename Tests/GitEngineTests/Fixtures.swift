import Foundation
import GitKit
import Testing

@testable import GitEngine

/// The environment every git run in these tests uses: no user or system config, no prompts.
let gitEnvironment: [String: String] = [
  "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "XDG_CONFIG_HOME": "/nonexistent",
  "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
  "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com", "GIT_TERMINAL_PROMPT": "0",
]

struct GitFailure: Error, CustomStringConvertible {
  var description: String
}

/// Runs git synchronously; throws with stderr when it fails.
@discardableResult
func git(_ arguments: [String], in directory: URL, input: Data? = nil, environment: [String: String] = [:]) throws
  -> String
{
  String(decoding: try gitData(arguments, in: directory, input: input, environment: environment), as: UTF8.self)
}

func gitData(_ arguments: [String], in directory: URL, input: Data? = nil, environment: [String: String] = [:]) throws
  -> Data
{
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = arguments
  process.currentDirectoryURL = directory
  process.environment = ProcessInfo.processInfo.environment.merging(gitEnvironment) { $1 }.merging(environment) { $1 }
  let output = Pipe()
  let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent("git-stderr-\(UUID().uuidString)")
  FileManager.default.createFile(atPath: errorFile.path, contents: nil)
  defer { try? FileManager.default.removeItem(at: errorFile) }
  process.standardOutput = output
  process.standardError = try FileHandle(forWritingTo: errorFile)
  let inputPipe = Pipe()
  process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
  try process.run()
  if let input {
    DispatchQueue.global().async {
      inputPipe.fileHandleForWriting.write(input)
      try? inputPipe.fileHandleForWriting.close()
    }
  }
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    let message = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
    throw GitFailure(description: "git \(arguments.joined(separator: " ")): \(message)")
  }
  return data
}

/// A throwaway repository made by real git, with the engine and GitKit (which runs real git) both pointed at it.
struct Fixture {
  static let runner = GitRunner(extraEnvironment: gitEnvironment)

  let parent: URL
  let root: URL

  init(name: String = "repo", initialize: Bool = true) throws {
    parent = FileManager.default.temporaryDirectory.appendingPathComponent("GitEngineTests-\(UUID().uuidString)")
      .resolvingSymlinksInPath()
    root = parent.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if initialize {
      try GitEngineTests.git(["init", "-q", "-b", "main"], in: root)
    }
  }

  /// Another folder next to this one.
  func sibling(_ name: String) -> URL { parent.appendingPathComponent(name) }

  var engine: LocalRepository { get throws { try LocalRepository(url: root) } }
  var gitKit: Repository { Repository(url: root, runner: Self.runner) }

  @discardableResult
  func git(_ arguments: String...) throws -> String { try GitEngineTests.git(arguments, in: root) }

  func write(_ path: String, _ text: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  func read(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
  }

  func exists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
  }

  func remove(_ path: String) throws {
    try FileManager.default.removeItem(at: root.appendingPathComponent(path))
  }

  func commitAll(_ message: String) throws {
    try git("add", "-A")
    try git("commit", "-q", "-m", message)
  }

  static func lines(_ range: ClosedRange<Int>, _ word: String = "line") -> String {
    range.map { "\(word) \($0)\n" }.joined()
  }

  static let author = GitSignature(name: "Engine", email: "engine@example.com")
}

/// Sorts status lists so comparisons don't depend on order where git's doesn't matter.
func normalized(_ status: WorkingTreeStatus) -> WorkingTreeStatus {
  var status = status
  status.staged.sort { $0.path < $1.path }
  status.unstaged.sort { $0.path < $1.path }
  status.conflicted.sort { $0.path < $1.path }
  return status
}

/// `git status --porcelain` lines, for quick checks.
func porcelain(_ fixture: Fixture) throws -> [String] {
  try fixture.git("status", "--porcelain", "--untracked-files=all").split(separator: "\n").map(String.init)
}
