import Foundation

public struct CalendarSyncFailure: Equatable, Sendable {
    public let provider: String
    public let message: String

    public init(provider: String, message: String) {
        self.provider = provider
        self.message = message
    }
}

public struct CalendarSyncReport: Sendable {
    public let meetings: [Meeting]
    public let failures: [CalendarSyncFailure]
    public let successfulProviderCount: Int

    public init(meetings: [Meeting], failures: [CalendarSyncFailure], successfulProviderCount: Int) {
        self.meetings = meetings
        self.failures = failures
        self.successfulProviderCount = successfulProviderCount
    }
}

public struct CalendarSyncService: Sendable {
    private let providers: [any MeetingCalendarProvider]

    public init(providers: [any MeetingCalendarProvider]) {
        self.providers = providers
    }

    public func syncReport(from start: Date, to end: Date) async -> CalendarSyncReport {
        var collected: [Meeting] = []
        var failures: [CalendarSyncFailure] = []
        var successfulProviderCount = 0
        for provider in providers {
            do {
                collected.append(contentsOf: try await provider.fetchMeetings(from: start, to: end))
                successfulProviderCount += 1
            } catch {
                failures.append(CalendarSyncFailure(provider: provider.name, message: error.localizedDescription))
            }
        }
        var unique: [String: Meeting] = [:]
        for meeting in collected { unique[meeting.id] = meeting }
        return CalendarSyncReport(meetings: unique.values.sorted { $0.start < $1.start },
                                  failures: failures,
                                  successfulProviderCount: successfulProviderCount)
    }

    public func sync(from start: Date, to end: Date) async throws -> [Meeting] {
        let report = await syncReport(from: start, to: end)
        if report.successfulProviderCount == 0, let failure = report.failures.first {
            throw CalendarProviderError.api("\(failure.provider): \(failure.message)")
        }
        return report.meetings
    }
}
