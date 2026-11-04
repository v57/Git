import Foundation
import Testing

@testable import GitKit

@Suite struct AutoFetchScheduleTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)
  private let schedule = AutoFetchSchedule()

  private func ago(hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

  @Test func theDefaultIsOnceADayWhenSelected() {
    #expect(schedule.interval == .day)
    #expect(schedule.moment.whenSelected)
    #expect(!schedule.moment.atStartup)
  }

  @Test func aRepositoryNeverFetchedIsDue() {
    #expect(schedule.isDue(lastFetched: nil, lastAttempt: nil, now: now))
  }

  @Test func aFetchWithinTheIntervalIsNotDue() {
    #expect(!schedule.isDue(lastFetched: ago(hours: 23), lastAttempt: nil, now: now))
    #expect(schedule.isDue(lastFetched: ago(hours: 24), lastAttempt: nil, now: now))
  }

  @Test func aFailedAttemptWaitsOutTheInterval() {
    #expect(!schedule.isDue(lastFetched: ago(hours: 72), lastAttempt: ago(hours: 1), now: now))
  }

  @Test func theLatestOfBothCounts() {
    #expect(!schedule.isDue(lastFetched: ago(hours: 1), lastAttempt: ago(hours: 72), now: now))
  }

  @Test func aboveInAppFirstHTTPSRemotesWaitForTheUser() {
    let https = ["https://github.com/owner/repo.git"]
    let ssh = ["git@github.com:owner/repo.git"]
    #expect(AutoFetchSchedule.allows(remoteURLs: https, at: .useGit))
    #expect(AutoFetchSchedule.allows(remoteURLs: https, at: .inAppFirst))
    #expect(!AutoFetchSchedule.allows(remoteURLs: https, at: .sshOnly))
    #expect(!AutoFetchSchedule.allows(remoteURLs: ssh + https, at: .vaultKeyOnly))
    #expect(AutoFetchSchedule.allows(remoteURLs: ssh, at: .vaultKeyOnly))
  }

  @Test func momentsCoverStartupAndSelection() {
    #expect(AutoFetchSchedule.Moment.both.atStartup && AutoFetchSchedule.Moment.both.whenSelected)
    #expect(AutoFetchSchedule.Moment.startup.atStartup && !AutoFetchSchedule.Moment.startup.whenSelected)
  }
}
