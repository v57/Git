import Foundation
import GitKit
import Observation

/// Settings ▸ Privacy's auto-fetch, on this device only: off until the user turns it on, and each device decides for
/// itself, since turning it on is consent to that device reaching out on its own. A fetch it starts is an ordinary
/// fetch, so it follows `GitSecurity.level`; repositories on other devices stay out at Vault key only.
@MainActor @Observable public final class AutoFetch {
  public static let shared = AutoFetch()

  private enum Keys {
    static let isOn = "AutoFetch.isOn"
    static let moment = "AutoFetch.moment"
    static let interval = "AutoFetch.interval"
    static let attempts = "AutoFetch.attempts"
  }

  public var isOn: Bool {
    didSet { defaults.set(isOn, forKey: Keys.isOn) }
  }

  public var schedule: AutoFetchSchedule {
    didSet {
      defaults.set(schedule.moment.rawValue, forKey: Keys.moment)
      defaults.set(schedule.interval.rawValue, forKey: Keys.interval)
    }
  }

  @ObservationIgnored private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    isOn = defaults.bool(forKey: Keys.isOn)
    let standard = AutoFetchSchedule()
    schedule = AutoFetchSchedule(
      moment: defaults.object(forKey: Keys.moment).flatMap { $0 as? Int }.flatMap(AutoFetchSchedule.Moment.init(rawValue:))
        ?? standard.moment,
      interval: defaults.object(forKey: Keys.interval).flatMap { $0 as? Int }
        .flatMap(AutoFetchSchedule.Interval.init(rawValue:)) ?? standard.interval)
  }

  /// Whether to fetch at startup now.
  public var runsAtStartup: Bool { isOn && schedule.moment.atStartup }

  /// Whether to fetch a repository as it's selected.
  public var runsOnSelection: Bool { isOn && schedule.moment.whenSelected }

  /// Whether the repository `key` names may be fetched now, by its last fetch and this feature's last attempt, and by
  /// the level: a repository on another device (`isOtherDevice`) stays out while the level turns off its network
  /// actions, and one here while its remotes (`remoteURLs`) would have to move (`AutoFetchSchedule.allows`).
  public func isDue(
    _ key: String, lastFetched: Date?, remoteURLs: [String] = [], isOtherDevice: Bool = false
  ) -> Bool {
    let level = GitSecurity.level
    if isOtherDevice {
      if level.otherDeviceRefusal != nil { return false }
    } else if !AutoFetchSchedule.allows(remoteURLs: remoteURLs, at: level) {
      return false
    }
    return schedule.isDue(lastFetched: lastFetched, lastAttempt: attempts[key])
  }

  /// Records that a fetch of `key` starts, whatever comes of it.
  public func noteAttempt(_ key: String) {
    var attempts = attempts
    attempts[key] = .now
    defaults.set(attempts, forKey: Keys.attempts)
  }

  private var attempts: [String: Date] { defaults.dictionary(forKey: Keys.attempts) as? [String: Date] ?? [:] }
}
