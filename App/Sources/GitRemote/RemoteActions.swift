import Foundation
import GitKit

/// A network operation started on repositories from a list.
public enum RemoteAction: String, Sendable {
  case fetch, pull, push

  public var title: String {
    switch self {
    case .fetch: "Fetch"
    case .pull: "Pull"
    case .push: "Push"
    }
  }

  public var systemImage: String {
    switch self {
    case .fetch: "arrow.clockwise"
    case .pull: "arrow.down.to.line"
    case .push: "arrow.up.to.line"
    }
  }

  public func run(in repository: Repository) async throws {
    switch self {
    case .fetch: try await repository.fetch()
    case .pull: try await repository.pull()
    case .push: try await repository.push()
    }
  }
}

/// Why fetching, pulling or pushing some repositories failed, for a notice.
public struct RemoteFailure: Identifiable, Sendable {
  public let id = UUID()
  public var title: String
  public var message: String

  public init(title: String, message: String) {
    self.title = title
    self.message = message
  }

  /// The notice for `failures`, or nil when there are none.
  public init?(_ action: RemoteAction, failures: [(name: String, message: String)]) {
    guard !failures.isEmpty else { return nil }
    let noun = failures.count == 1 ? failures[0].name : String(localized: "\(failures.count) repositories")
    title = "Couldn't \(action.title.lowercased()) \(noun)"
    message = Self.reasons(failures, lines: 3).joined(separator: "\n\n")
  }

  /// One paragraph per distinct reason, its first `lines` lines, in the order first seen (G-011: a refresh of 83
  /// repositories with Vault key only on said the same sentence 83 times). A reason all of them share stands alone
  /// (the title names how many); otherwise each says which: up to three names, or "12 repositories".
  public static func reasons(_ failures: [(name: String, message: String)], lines: Int) -> [String] {
    var order: [String] = []
    var names: [String: [String]] = [:]
    for failure in failures {
      let message = failure.message.split(separator: "\n").prefix(lines).joined(separator: "\n")
      if names[message] == nil { order.append(message) }
      names[message, default: []].append(failure.name)
    }
    guard order.count > 1 else { return order }
    return order.map { message in
      let group = names[message] ?? []
      let who = group.count <= 3 ? group.joined(separator: ", ") : String(localized: "\(group.count) repositories")
      return "\(who): \(message)"
    }
  }
}
