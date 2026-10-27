import CryptoKit
import Foundation

/// The four kinds of stored object, numbered as in pack files.
enum ObjectType: Int, Sendable {
  case commit = 1, tree = 2, blob = 3, tag = 4

  var name: String {
    switch self {
    case .commit: "commit"
    case .tree: "tree"
    case .blob: "blob"
    case .tag: "tag"
    }
  }

  init?(name: some StringProtocol) {
    switch name {
    case "commit": self = .commit
    case "tree": self = .tree
    case "blob": self = .blob
    case "tag": self = .tag
    default: return nil
    }
  }
}

/// An object's type and contents (without the `type size\0` header).
struct GitObject: Sendable {
  var type: ObjectType
  var data: Data

  /// `blob 12\0`: what git hashes and stores in front of the contents.
  static func header(_ type: ObjectType, size: Int) -> Data { Data("\(type.name) \(size)\0".utf8) }

  static func id(_ type: ObjectType, _ data: Data) -> ObjectID {
    var hasher = Insecure.SHA1()
    hasher.update(data: header(type, size: data.count))
    hasher.update(data: data)
    return ObjectID(bytes: Array(hasher.finalize()))
  }

  var id: ObjectID { Self.id(type, data) }
}

/// File modes git stores in trees and the index.
enum FileMode: UInt32, Sendable {
  case regular = 0o100644
  case executable = 0o100755
  case symlink = 0o120000
  case tree = 0o040000
  case gitlink = 0o160000

  /// Normalizes what git may find in old trees (e.g. `100664`) to the modes it writes.
  init(raw: UInt32) {
    switch raw & 0o170000 {
    case 0o040000: self = .tree
    case 0o120000: self = .symlink
    case 0o160000: self = .gitlink
    default: self = raw & 0o111 != 0 ? .executable : .regular
    }
  }

  /// `100644`, as diffs show it.
  var octal: String { String(rawValue, radix: 8, uppercase: false).leftPadded(to: 6) }
  /// As trees store it: without a leading zero.
  var treeOctal: String { String(rawValue, radix: 8) }
  var isFile: Bool { self == .regular || self == .executable }
}

extension String {
  func leftPadded(to width: Int) -> String {
    count >= width ? self : String(repeating: "0", count: width - count) + self
  }
}
