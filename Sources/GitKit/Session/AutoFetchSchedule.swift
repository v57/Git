import Foundation

/// When auto-fetch runs (Settings ▸ Privacy): the moments the user picked, and how often a repository may be fetched.
public struct AutoFetchSchedule: Sendable, Hashable {
  public enum Moment: Int, Sendable, CaseIterable, Identifiable {
    case startup, selection, both

    public var id: Int { rawValue }
    public var atStartup: Bool { self != .selection }
    public var whenSelected: Bool { self != .startup }
  }

  public enum Interval: Int, Sendable, CaseIterable, Identifiable {
    case hour, day, week

    public var id: Int { rawValue }

    public var seconds: TimeInterval {
      switch self {
      case .hour: 60 * 60
      case .day: 24 * 60 * 60
      case .week: 7 * 24 * 60 * 60
      }
    }
  }

  public var moment: Moment
  public var interval: Interval

  public init(moment: Moment = .selection, interval: Interval = .day) {
    self.moment = moment
    self.interval = interval
  }

  /// Whether a fetch nobody just asked for may use these remote addresses. From SSH only up an HTTPS remote moves to SSH
  /// or is refused, and moving one takes an action the user started (`RemoteMover`), so it waits for that.
  public static func allows(remoteURLs: [String], at level: GitSecurityLevel) -> Bool {
    guard level >= .sshOnly else { return true }
    return !remoteURLs.contains { $0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") }
  }

  /// Whether a repository may be fetched now: nothing reached its server for a whole interval. `lastFetched` counts any
  /// fetch, by the user or in Terminal; `lastAttempt` is auto-fetch's own, so one that fails waits out the interval too.
  public func isDue(lastFetched: Date?, lastAttempt: Date?, now: Date = .now) -> Bool {
    guard let last = [lastFetched, lastAttempt].compactMap({ $0 }).max() else { return true }
    return now.timeIntervalSince(last) >= interval.seconds
  }
}
