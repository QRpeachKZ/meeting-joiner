import Foundation

public enum ReminderAction: Sendable {
    case connect
    case skip
}

public protocol ConferenceURLOpening: Sendable {
    func open(_ url: URL)
}

public final class ReminderCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var shownIDs = Set<String>()
    private var dismissedIDs = Set<String>()
    private let opener: any ConferenceURLOpening

    public init(opener: any ConferenceURLOpening, dismissedMeetingIDs: Set<String> = []) {
        self.opener = opener
        self.dismissedIDs = dismissedMeetingIDs
    }

    public var dismissedMeetingIDs: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return dismissedIDs
    }

    public func retainDismissedIDs(keeping meetingIDs: Set<String>) {
        lock.lock()
        dismissedIDs.formIntersection(meetingIDs)
        lock.unlock()
    }

    /// Returns meetings whose start falls within the look-back window, once per app run.
    public func remindersToShow(for meetings: [Meeting], now: Date, lookBack: TimeInterval = 300) -> [Meeting] {
        lock.lock()
        defer { lock.unlock() }
        return meetings.filter { meeting in
            meeting.conferenceURL != nil && meeting.start <= now && meeting.start >= now.addingTimeInterval(-lookBack)
                && !shownIDs.contains(meeting.id) && !dismissedIDs.contains(meeting.id)
        }.sorted { $0.start < $1.start }.filter { shownIDs.insert($0.id).inserted }
    }

    /// Only an explicit Connect action opens the conference URL. Skip is remembered for this meeting.
    @discardableResult
    public func handle(_ action: ReminderAction, for meeting: Meeting) -> Bool {
        switch action {
        case .connect:
            guard let url = meeting.conferenceURL else { return false }
            opener.open(url)
            return true
        case .skip:
            lock.lock()
            dismissedIDs.insert(meeting.id)
            lock.unlock()
            return true
        }
    }
}
