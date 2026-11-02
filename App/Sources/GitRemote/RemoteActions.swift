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
    let noun = failures.count == 1 ? "repository" : "\(failures.count) repositories"
    title = "Couldn't \(action.title.lowercased()) \(failures.count == 1 ? failures[0].name : noun)"
    message = failures.map { failure in
      let message = failure.message.split(separator: "\n").prefix(3).joined(separator: "\n")
      return failures.count == 1 ? message : "\(failure.name): \(message)"
    }.joined(separator: "\n\n")
  }
}
