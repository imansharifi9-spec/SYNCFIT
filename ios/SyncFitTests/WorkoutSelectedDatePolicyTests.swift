import XCTest
@testable import SyncFit

final class WorkoutSelectedDatePolicyTests: XCTestCase {
    func testFollowingTodaySnapsAcrossDayRollover() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let wednesday = calendar.date(from: DateComponents(year: 2026, month: 7, day: 15))!
        let thursday = calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 9))!

        let resolved = WorkoutSelectedDatePolicy.resolvedDate(
            current: wednesday,
            followsToday: true,
            now: thursday,
            calendar: calendar
        )

        XCTAssertTrue(
            calendar.isDate(resolved, inSameDayAs: thursday),
            "When following today, a Wed→Thu rollover must snap selectedDate to Thursday"
        )
        XCTAssertFalse(calendar.isDate(resolved, inSameDayAs: wednesday))
    }

    func testManualPastDayIsNotYankedOnRefresh() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let monday = calendar.date(from: DateComponents(year: 2026, month: 7, day: 13))!
        let thursday = calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 9))!

        let resolved = WorkoutSelectedDatePolicy.resolvedDate(
            current: monday,
            followsToday: false,
            now: thursday,
            calendar: calendar
        )

        XCTAssertTrue(
            calendar.isDate(resolved, inSameDayAs: monday),
            "Manual browse of another day must not snap to today on refresh"
        )
    }

    func testSelectingTodayReenablesFollowMode() {
        let today = Calendar.current.startOfDay(for: .now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!

        XCTAssertTrue(WorkoutSelectedDatePolicy.followsTodayAfterSelection(today))
        XCTAssertFalse(WorkoutSelectedDatePolicy.followsTodayAfterSelection(yesterday))
    }
}
