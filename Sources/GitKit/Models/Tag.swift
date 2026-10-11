import Foundation

/// A tag, with the commit it points to.
public struct Tag: Sendable, Hashable, Identifiable {
  public var name: String
  /// The tagged commit (the target of an annotated tag).
  public var commit: String
  public var date: Date?

  public init(name: String, commit: String, date: Date? = nil) {
    self.name = name
    self.commit = commit
    self.date = date
  }

  public var id: String { name }
}

/// Lines added and removed in one file. `nil` counts mean a binary file.
public struct LineCounts: Sendable, Hashable {
  public var added: Int?
  public var removed: Int?

  public init(added: Int?, removed: Int?) {
    self.added = added
    self.removed = removed
  }
}
