import Foundation
import GitKit

/// A parsed commit object.
struct CommitObject: Sendable {
  var tree: ObjectID
  var parents: [ObjectID]
  var author: GitSignature
  var committer: GitSignature
  /// Everything after the headers' blank line.
  var message: String

  init(tree: ObjectID, parents: [ObjectID], author: GitSignature, committer: GitSignature, message: String) {
    self.tree = tree
    self.parents = parents
    self.author = author
    self.committer = committer
    self.message = message
  }

  init(_ data: Data) throws {
    var tree: ObjectID?
    var parents: [ObjectID] = []
    var author: GitSignature?
    var committer: GitSignature?
    let bytes = [UInt8](data)
    var start = 0
    var messageStart = bytes.count
    while start < bytes.count {
      let end = bytes[start...].firstIndex(of: 0x0A) ?? bytes.count
      if end == start {
        messageStart = end + 1
        break
      }
      // Continuation lines (a signature's) start with a space.
      if bytes[start] != 0x20 {
        let line = String(decoding: bytes[start..<end], as: UTF8.self)
        if line.hasPrefix("tree ") {
          tree = ObjectID(hex: line.dropFirst(5))
        } else if line.hasPrefix("parent ") {
          if let parent = ObjectID(hex: line.dropFirst(7)) { parents.append(parent) }
        } else if line.hasPrefix("author ") {
          author = GitSignature(encoded: line.dropFirst(7))
        } else if line.hasPrefix("committer ") {
          committer = GitSignature(encoded: line.dropFirst(10))
        }
      }
      start = end + 1
    }
    guard let tree else { throw GitEngineError.corrupt("A commit has no tree.") }
    self.tree = tree
    self.parents = parents
    let unknown = GitSignature(name: "", email: "", date: Date(timeIntervalSince1970: 0))
    self.author = author ?? committer ?? unknown
    self.committer = committer ?? author ?? unknown
    message = messageStart < bytes.count ? String(decoding: bytes[messageStart...], as: UTF8.self) : ""
  }

  var encoded: Data {
    var text = "tree \(tree.hex)\n"
    for parent in parents { text += "parent \(parent.hex)\n" }
    text += "author \(author.encoded)\ncommitter \(committer.encoded)\n\n\(message)"
    return Data(text.utf8)
  }

  /// git's `%s`: the first paragraph, its lines joined with spaces.
  var subject: String {
    let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
    var paragraph: [Substring] = []
    for line in lines.drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
      if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
      paragraph.append(line)
    }
    return paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
  }

  /// git's `%b`: everything after the first paragraph, trimmed.
  var body: String {
    let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
      .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
    let rest = lines.drop(while: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    return rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func model(id: ObjectID, refs: [RefLabel]) -> Commit {
    Commit(
      id: id.hex, parents: parents.map(\.hex), authorName: author.name, authorEmail: author.email,
      authorDate: author.date, committerName: committer.name, committerEmail: committer.email,
      committerDate: committer.date, refs: refs, subject: subject, body: body)
  }
}

/// An annotated tag: what it points to.
struct TagObject: Sendable {
  var object: ObjectID
  var type: ObjectType

  init(_ data: Data) throws {
    var object: ObjectID?
    var type = ObjectType.commit
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
      if line.isEmpty { break }
      if line.hasPrefix("object ") { object = ObjectID(hex: line.dropFirst(7)) }
      if line.hasPrefix("type "), let parsed = ObjectType(name: line.dropFirst(5)) { type = parsed }
    }
    guard let object else { throw GitEngineError.corrupt("A tag has no object.") }
    self.object = object
    self.type = type
  }
}
