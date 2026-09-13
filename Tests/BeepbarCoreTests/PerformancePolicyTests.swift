import XCTest
@testable import BeepbarCore

final class PerformancePolicyTests: XCTestCase {
    func testProgressThrottleLimitsIntermediateUpdatesAndAlwaysDeliversFinal() {
        let clock = ContinuousClock()
        let start = clock.now
        var throttle = SyncProgressThrottle(minimumInterval: .milliseconds(200))

        var publications = 0
        for completed in 0..<10_000 {
            let progress = SyncProgress(completed: completed, total: 10_000, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
            if throttle.accept(progress, now: start) != nil { publications += 1 }
        }
        XCTAssertEqual(publications, 1)

        throttle.reset()
        let first = SyncProgress(completed: 0, total: 10_000, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
        XCTAssertEqual(throttle.accept(first, now: start), first)
        let second = SyncProgress(completed: 1, total: 10_000, installed: 1, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
        XCTAssertNil(throttle.accept(second, now: start.advanced(by: .milliseconds(199))))
        XCTAssertEqual(throttle.accept(second, now: start.advanced(by: .milliseconds(200))), second)

        let final = SyncProgress(completed: 10_000, total: 10_000, installed: 10_000, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
        XCTAssertEqual(throttle.accept(final, now: start.advanced(by: .milliseconds(201))), final)
    }

    func testProgressThrottleRejectsRegressionsAndResets() {
        let clock = ContinuousClock()
        let now = clock.now
        var throttle = SyncProgressThrottle(minimumInterval: .zero)
        XCTAssertNotNil(throttle.accept(SyncProgress(completed: 4, total: 10, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0), now: now))
        XCTAssertNil(throttle.accept(SyncProgress(completed: 3, total: 10, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0), now: now))
        throttle.reset()
        XCTAssertNotNil(throttle.accept(SyncProgress(completed: 0, total: 10, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0), now: now))
    }

    func testAutomaticSchedulingRequiresEveryPrerequisite() {
        let valid = BackgroundScheduleInput(automaticSyncEnabled: true, hasCredential: true, hasRoot: true, enabledCourseCount: 1, recoveryBlocked: false)
        XCTAssertTrue(BackgroundSchedulePolicy.shouldSchedule(valid))
        XCTAssertFalse(BackgroundSchedulePolicy.shouldSchedule(.init(automaticSyncEnabled: false, hasCredential: true, hasRoot: true, enabledCourseCount: 1, recoveryBlocked: false)))
        XCTAssertFalse(BackgroundSchedulePolicy.shouldSchedule(.init(automaticSyncEnabled: true, hasCredential: false, hasRoot: true, enabledCourseCount: 1, recoveryBlocked: false)))
        XCTAssertFalse(BackgroundSchedulePolicy.shouldSchedule(.init(automaticSyncEnabled: true, hasCredential: true, hasRoot: false, enabledCourseCount: 1, recoveryBlocked: false)))
        XCTAssertFalse(BackgroundSchedulePolicy.shouldSchedule(.init(automaticSyncEnabled: true, hasCredential: true, hasRoot: true, enabledCourseCount: 0, recoveryBlocked: false)))
        XCTAssertFalse(BackgroundSchedulePolicy.shouldSchedule(.init(automaticSyncEnabled: true, hasCredential: true, hasRoot: true, enabledCourseCount: 1, recoveryBlocked: true)))
    }
}
