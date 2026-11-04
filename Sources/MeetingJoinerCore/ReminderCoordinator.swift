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
    private var pendingIDs = Set<String>()
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

    /// Returns ongoing meetings once per app run, including after a delay or sleep.
    public func remindersToShow(for meetings: [Meeting], now: Date) -> [Meeting] {
        lock.lock()
        defer { lock.unlock() }
        return meetings.filter { meeting in
            meeting.start <= now && now < meeting.end
                && !shownIDs.contains(meeting.id) && !dismissedIDs.contains(meeting.id)
                && validConferenceURL(for: meeting) != nil
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }.filter { meeting in
            guard shownIDs.insert(meeting.id).inserted else { return false }
            pendingIDs.insert(meeting.id)
            return true
        }
    }

    /// Reading the pending queue never marks new reminders as shown.
    public func pendingReminders(for meetings: [Meeting], now: Date) -> [Meeting] {
        lock.lock()
        defer { lock.unlock() }
        var retainedIDs = Set<String>()
        let pending = meetings.filter { meeting in
            pendingIDs.contains(meeting.id) && !dismissedIDs.contains(meeting.id)
                && meeting.start <= now && now < meeting.end
                && validConferenceURL(for: meeting) != nil
                && retainedIDs.insert(meeting.id).inserted
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        pendingIDs = retainedIDs
        return pending
    }

    private func validConferenceURL(for meeting: Meeting) -> URL? {
        guard let url = meeting.conferenceURL, url.user == nil, url.password == nil,
              ConferenceURLRecognizer.firstURL(in: url.absoluteString) == url else { return nil }
        return url
    }

    /// Only an explicit Connect action opens the conference URL. Skip is remembered for this meeting.
    @discardableResult
    public func handle(_ action: ReminderAction, for meeting: Meeting) -> Bool {
        switch action {
        case .connect:
            guard let url = validConferenceURL(for: meeting) else { return false }
            lock.lock()
            pendingIDs.remove(meeting.id)
            lock.unlock()
            opener.open(url)
            return true
        case .skip:
            lock.lock()
            pendingIDs.remove(meeting.id)
            dismissedIDs.insert(meeting.id)
            lock.unlock()
            return true
        }
    }
}
