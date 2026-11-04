import Foundation
import XCTest
@testable import MeetingJoinerCore

final class ReminderPopoverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 30_000)

    func testOnlyOngoingMeetingsBecomePending() {
        let opener = RecordingOpener()
        let coordinator = ReminderCoordinator(opener: opener)
        let ongoing = meeting("ongoing", startOffset: -600)
        let startingNow = meeting("starting-now")
        let future = meeting("future", startOffset: 1)
        let ended = meeting("ended", startOffset: -600, endOffset: -1)
        let endingNow = meeting("ending-now", startOffset: -600, endOffset: 0)
        let meetings = [future, ended, startingNow, endingNow, ongoing]

        XCTAssertEqual(coordinator.remindersToShow(for: meetings, now: now), [ongoing, startingNow])
        XCTAssertEqual(coordinator.pendingReminders(for: meetings, now: now), [ongoing, startingNow])
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testReadingPendingDoesNotEnqueueOrMarkNewDueMeetings() {
        let coordinator = ReminderCoordinator(opener: RecordingOpener())
        let due = meeting("due")

        XCTAssertTrue(coordinator.pendingReminders(for: [due], now: now).isEmpty)
        XCTAssertEqual(coordinator.remindersToShow(for: [due], now: now), [due])
        XCTAssertEqual(coordinator.pendingReminders(for: [due], now: now), [due])
    }

    func testSimultaneousMeetingsHaveDeterministicOrderAndNoDuplicates() {
        let coordinator = ReminderCoordinator(opener: RecordingOpener())
        let first = meeting("a")
        let second = meeting("b")
        let meetings = [second, first, second]

        XCTAssertEqual(coordinator.remindersToShow(for: meetings, now: now), [first, second])
        XCTAssertEqual(coordinator.pendingReminders(for: meetings, now: now), [first, second])
        XCTAssertEqual(coordinator.pendingReminders(for: [first, second], now: now), [first, second])
    }

    func testClosingWithoutActionRetainsQueueWithoutGeneratingRemindersAgain() {
        let opener = RecordingOpener()
        let coordinator = ReminderCoordinator(opener: opener)
        let meetings = [meeting("a"), meeting("b")]
        XCTAssertEqual(coordinator.remindersToShow(for: meetings, now: now), meetings)
        XCTAssertEqual(coordinator.pendingReminders(for: meetings, now: now), meetings)

        // Closing the popover invokes no coordinator action; subsequent ticks only read the queue.
        for seconds in [1.0, 2.0, 30.0] {
            let tick = now.addingTimeInterval(seconds)
            XCTAssertTrue(coordinator.remindersToShow(for: meetings, now: tick).isEmpty)
            XCTAssertEqual(coordinator.pendingReminders(for: meetings, now: tick), meetings)
        }
        XCTAssertTrue(coordinator.dismissedMeetingIDs.isEmpty)
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testConnectRemovesOnlySelectedMeetingAndOpensOnce() {
        let opener = RecordingOpener()
        let coordinator = ReminderCoordinator(opener: opener)
        let selected = meeting("a")
        let remaining = meeting("b")
        let meetings = [selected, remaining]
        _ = coordinator.remindersToShow(for: meetings, now: now)
        XCTAssertTrue(opener.opened.isEmpty)

        XCTAssertTrue(coordinator.handle(.connect, for: selected))
        XCTAssertEqual(opener.opened, [selected.conferenceURL!])
        XCTAssertEqual(coordinator.pendingReminders(for: meetings, now: now), [remaining])
        XCTAssertTrue(coordinator.remindersToShow(for: meetings, now: now).isEmpty)
        XCTAssertTrue(coordinator.dismissedMeetingIDs.isEmpty)
    }

    func testSkipRemovesOnlySelectedMeetingAndSurvivesRestoration() {
        let opener = RecordingOpener()
        let coordinator = ReminderCoordinator(opener: opener)
        let selected = meeting("a")
        let remaining = meeting("b")
        let meetings = [selected, remaining]
        _ = coordinator.remindersToShow(for: meetings, now: now)

        XCTAssertTrue(coordinator.handle(.skip, for: selected))
        XCTAssertEqual(coordinator.pendingReminders(for: meetings, now: now), [remaining])
        XCTAssertTrue(coordinator.remindersToShow(for: meetings, now: now).isEmpty)
        XCTAssertEqual(coordinator.dismissedMeetingIDs, [selected.id])

        let restored = ReminderCoordinator(opener: opener, dismissedMeetingIDs: coordinator.dismissedMeetingIDs)
        XCTAssertTrue(restored.pendingReminders(for: meetings, now: now).isEmpty)
        XCTAssertEqual(restored.remindersToShow(for: meetings, now: now), [remaining])
        XCTAssertEqual(restored.pendingReminders(for: meetings, now: now), [remaining])
        XCTAssertEqual(restored.dismissedMeetingIDs, [selected.id])
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testExpiryPrunesPendingIDsWithoutShowingAgain() {
        let coordinator = ReminderCoordinator(opener: RecordingOpener())
        let expiring = meeting("expiring", endOffset: 1)
        let remaining = meeting("remaining")
        let meetings = [expiring, remaining]
        _ = coordinator.remindersToShow(for: meetings, now: now)

        XCTAssertEqual(coordinator.pendingReminders(for: meetings, now: now.addingTimeInterval(1)), [remaining])
        // Even if a sync extends the ended meeting, its pending ID has been pruned.
        var extended = expiring
        extended.end = now.addingTimeInterval(600)
        let updated = [extended, remaining]
        XCTAssertEqual(coordinator.pendingReminders(for: updated, now: now.addingTimeInterval(2)), [remaining])
        XCTAssertTrue(coordinator.remindersToShow(for: updated, now: now.addingTimeInterval(2)).isEmpty)
    }

    func testCancelledMeetingAbsentFromCurrentSnapshotIsPruned() {
        let coordinator = ReminderCoordinator(opener: RecordingOpener())
        let cancelled = meeting("cancelled")
        let remaining = meeting("remaining")
        let meetings = [cancelled, remaining]
        _ = coordinator.remindersToShow(for: meetings, now: now)

        XCTAssertEqual(coordinator.pendingReminders(for: [remaining], now: now), [remaining])
        XCTAssertEqual(coordinator.pendingReminders(for: meetings, now: now), [remaining])
        XCTAssertTrue(coordinator.remindersToShow(for: meetings, now: now).isEmpty)
        XCTAssertTrue(coordinator.pendingReminders(for: [], now: now).isEmpty)
        XCTAssertTrue(coordinator.pendingReminders(for: meetings, now: now).isEmpty)
    }

    func testRescheduledFutureMeetingIsPruned() {
        let coordinator = ReminderCoordinator(opener: RecordingOpener())
        let original = meeting("rescheduled")
        _ = coordinator.remindersToShow(for: [original], now: now)
        var rescheduled = original
        rescheduled.start = now.addingTimeInterval(60)

        XCTAssertTrue(coordinator.pendingReminders(for: [rescheduled], now: now).isEmpty)
        XCTAssertTrue(coordinator.pendingReminders(for: [rescheduled], now: rescheduled.start).isEmpty)
        XCTAssertTrue(coordinator.remindersToShow(for: [rescheduled], now: rescheduled.start).isEmpty)
    }

    func testPendingReturnsUpdatedMetadataFromCurrentSnapshot() {
        let opener = RecordingOpener()
        let coordinator = ReminderCoordinator(opener: opener)
        let original = meeting("updated")
        _ = coordinator.remindersToShow(for: [original], now: now)
        var updated = original
        updated.title = "Updated meeting title"
        updated.start = now.addingTimeInterval(-120)
        updated.end = now.addingTimeInterval(1200)
        updated.conferenceURL = URL(string: "https://zoom.us/j/987654")!

        let pending = coordinator.pendingReminders(for: [updated], now: now)
        XCTAssertEqual(pending, [updated])
        XCTAssertTrue(opener.opened.isEmpty)
        if let selected = pending.first {
            XCTAssertTrue(coordinator.handle(.connect, for: selected))
        }
        XCTAssertEqual(opener.opened, [updated.conferenceURL!])
        XCTAssertTrue(coordinator.pendingReminders(for: [updated], now: now).isEmpty)
    }

    func testUnsafeOrMissingURLNeverQueuesOrOpens() {
        let opener = RecordingOpener()
        let coordinator = ReminderCoordinator(opener: opener)
        let unsafeURLs: [String?] = [
            nil,
            "http://meet.google.com/abc-defg-hij",
            "https://zoom.us.attacker.example/j/123",
            "https://user:password@zoom.us/j/123",
            "file:///tmp/conference"
        ]
        for (index, value) in unsafeURLs.enumerated() {
            var unsafe = meeting("unsafe-\(index)")
            unsafe.conferenceURL = value.flatMap { URL(string: $0) }
            XCTAssertTrue(coordinator.remindersToShow(for: [unsafe], now: now).isEmpty)
            XCTAssertTrue(coordinator.pendingReminders(for: [unsafe], now: now).isEmpty)
            XCTAssertFalse(coordinator.handle(.connect, for: unsafe))
        }
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testInvalidUpdatedURLIsPrunedButRejectedConnectDoesNotConsumePendingID() {
        let opener = RecordingOpener()
        let coordinator = ReminderCoordinator(opener: opener)
        let original = meeting("updated-url")
        _ = coordinator.remindersToShow(for: [original], now: now)
        var unsafe = original
        unsafe.conferenceURL = URL(string: "https://zoom.us.attacker.example/j/123")!

        XCTAssertFalse(coordinator.handle(.connect, for: unsafe))
        XCTAssertEqual(coordinator.pendingReminders(for: [original], now: now), [original])
        XCTAssertTrue(coordinator.pendingReminders(for: [unsafe], now: now).isEmpty)
        XCTAssertTrue(coordinator.pendingReminders(for: [original], now: now).isEmpty)
        XCTAssertTrue(coordinator.remindersToShow(for: [original], now: now).isEmpty)
        XCTAssertTrue(opener.opened.isEmpty)
    }

    private func meeting(_ id: String, startOffset: TimeInterval = 0, endOffset: TimeInterval = 600) -> Meeting {
        Meeting(id: id, title: id, start: now.addingTimeInterval(startOffset),
                end: now.addingTimeInterval(endOffset),
                conferenceURL: URL(string: "https://meet.google.com/abc-defg-hij")!)
    }

    private final class RecordingOpener: ConferenceURLOpening, @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        var opened: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }

        func open(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            urls.append(url)
        }
    }
}
