import XCTest
@testable import Pretype

/// When the field is re-read after an edit: the notifications' coalesced read,
/// and the keystroke timer's fallback that stands down only when that read got
/// the field.
final class RereadScheduleTests: XCTestCase {
    /// One edit: a key, then (if the app posts them) its two notifications and
    /// their coalesced read, which gets the field or not. Then the keystroke's
    /// fallback timer fires: whether it reads.
    private func edit(_ schedule: inout RereadSchedule, notifications: Bool, readGetsField: Bool = true) -> Bool {
        schedule.keyPressed()
        XCTAssertTrue(schedule.requestKeyReread(fallback: true))
        if notifications {
            XCTAssertTrue(schedule.notified(valueChanged: false))
            XCTAssertFalse(schedule.notified(valueChanged: true), "coalesced into one read")
            schedule.notifiedReadStarts()
            if readGetsField { schedule.fieldRead() }
            schedule.notifiedReadEnded()
        }
        return schedule.keyRereadFired()
    }

    func testTheFallbackStandsDownOnlyForAReadThatGotTheField() {
        var schedule = RereadSchedule()
        XCTAssertTrue(edit(&schedule, notifications: false), "no notifications: the fallback reads")
        XCTAssertFalse(edit(&schedule, notifications: true), "a read after both notifications got it")
        // Every key starts over: the next edit, in an app whose notifications
        // stopped coming, gets its fallback.
        XCTAssertTrue(edit(&schedule, notifications: false))
        XCTAssertTrue(edit(&schedule, notifications: true, readGetsField: false), "a timed-out read")
    }

    // One notification without the other is no proof the edit was read —
    // either one.
    func testOneNotificationIsNotEnough() {
        for valueChanged in [true, false] {
            var schedule = RereadSchedule()
            schedule.keyPressed()
            XCTAssertTrue(schedule.requestKeyReread(fallback: true))
            XCTAssertTrue(schedule.notified(valueChanged: valueChanged))
            schedule.notifiedReadStarts()
            schedule.fieldRead()
            schedule.notifiedReadEnded()
            XCTAssertTrue(schedule.keyRereadFired(), "value changed: \(valueChanged)")
        }
    }

    // The notifications seen are a key's own: the next key's single one is
    // no proof, whatever the last key saw.
    func testEachKeyCountsItsOwnNotifications() {
        var schedule = RereadSchedule()
        XCTAssertFalse(edit(&schedule, notifications: true))
        schedule.keyPressed()
        XCTAssertTrue(schedule.requestKeyReread(fallback: true))
        XCTAssertTrue(schedule.notified(valueChanged: true))
        schedule.notifiedReadStarts()
        schedule.fieldRead()
        schedule.notifiedReadEnded()
        XCTAssertTrue(schedule.keyRereadFired())
    }

    // A retry asked for while the fallback is pending rides its timer, and
    // reads even after a notified read.
    func testARetryOnTheSameTimerAlwaysReads() {
        var schedule = RereadSchedule()
        schedule.keyPressed()
        XCTAssertTrue(schedule.requestKeyReread(fallback: true))
        XCTAssertFalse(schedule.requestKeyReread(fallback: false), "one timer")
        XCTAssertTrue(schedule.notified(valueChanged: false))
        XCTAssertTrue(schedule.notified(valueChanged: true) == false)
        schedule.notifiedReadStarts()
        schedule.fieldRead()
        schedule.notifiedReadEnded()
        XCTAssertTrue(schedule.keyRereadFired())
        XCTAssertTrue(schedule.requestKeyReread(fallback: true), "fired: a new one may be scheduled")
        XCTAssertTrue(schedule.notified(valueChanged: true), "read done: the next notification schedules again")
    }
}
