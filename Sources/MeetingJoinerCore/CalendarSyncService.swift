import Foundation

public struct CalendarSyncFailure: Equatable, Sendable {
    public let provider: String
    public let message: String

    public init(provider: String, message: String) {
        self.provider = provider
        self.message = message
    }
}

public struct CalendarProviderSnapshot: Sendable {
    public let provider: String
    public let meetings: [Meeting]

    public init(provider: String, meetings: [Meeting]) {
        self.provider = provider
        self.meetings = meetings
    }
}

public struct CalendarSyncReport: Sendable {
    public let successfulSnapshots: [CalendarProviderSnapshot]
    public let failures: [CalendarSyncFailure]
    public var successfulProviderCount: Int { successfulSnapshots.count }
    public var meetings: [Meeting] { sortedUniqueMeetings(successfulSnapshots.flatMap(\.meetings)) }

    public init(successfulSnapshots: [CalendarProviderSnapshot], failures: [CalendarSyncFailure]) {
        self.successfulSnapshots = successfulSnapshots
        self.failures = failures
    }
}

public struct CalendarMeetingSnapshots: Sendable {
    private var snapshots: [CalendarProviderSnapshot] = []

    public init() {}

    public var meetings: [Meeting] { sortedUniqueMeetings(snapshots.flatMap(\.meetings)) }

    public mutating func remove(providers: Set<String>) {
        snapshots.removeAll { providers.contains($0.provider) }
    }

    public mutating func apply(_ report: CalendarSyncReport, now: Date) {
        snapshots = snapshots.map {
            CalendarProviderSnapshot(provider: $0.provider, meetings: $0.meetings.filter { $0.end > now })
        }
        for snapshot in report.successfulSnapshots {
            snapshots.removeAll { $0.provider == snapshot.provider }
            snapshots.append(snapshot)
        }
    }
}

public struct CalendarSyncConfiguration: Equatable, Sendable {
    public static let googleProviderName = "Google Calendar"
    public static let exchangeProviderName = "Exchange (EWS)"

    public let exchange: ExchangeSettings

    public init(exchange: ExchangeSettings) {
        self.exchange = exchange
    }

    public var isExchangeEnabled: Bool {
        !exchange.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func validateInterval() throws {
        guard (1...1_440).contains(exchange.syncIntervalMinutes) else {
            throw ExchangeSettingsError.invalidSyncInterval
        }
    }

    public func validate() throws {
        try validateInterval()
        if isExchangeEnabled { try exchange.validate() }
    }

    public func changedSources(from previous: CalendarSyncConfiguration) -> Set<String> {
        var changed = Set<String>()
        if exchange.serverURL != previous.exchange.serverURL || exchange.port != previous.exchange.port
            || exchange.domain != previous.exchange.domain || exchange.username != previous.exchange.username {
            changed.insert(Self.exchangeProviderName)
        }
        return changed
    }
}

public struct CalendarSyncFlight: Sendable {
    public private(set) var revision: UInt = 0
    private var isRunning = false
    private var needsRerun = false

    public init() {}

    public mutating func configurationDidChange() {
        revision &+= 1
        if isRunning { needsRerun = true }
    }

    public mutating func settingsDidSave(from previous: CalendarSyncConfiguration, to current: CalendarSyncConfiguration,
                                         secretsChanged: Bool) {
        if previous != current || secretsChanged { configurationDidChange() }
    }

    public func isCurrent(_ revision: UInt) -> Bool { self.revision == revision }

    public mutating func begin() -> UInt? {
        guard !isRunning else {
            needsRerun = true
            return nil
        }
        isRunning = true
        return revision
    }

    public mutating func finish() -> UInt? {
        if needsRerun {
            needsRerun = false
            return revision
        }
        isRunning = false
        return nil
    }
}

public struct CalendarSyncService: Sendable {
    private let providers: [any MeetingCalendarProvider]

    public init(providers: [any MeetingCalendarProvider]) {
        self.providers = providers
    }

    public func syncReport(from start: Date, to end: Date) async -> CalendarSyncReport {
        var snapshots: [CalendarProviderSnapshot] = []
        var failures: [CalendarSyncFailure] = []
        for provider in providers {
            do {
                let meetings = try await provider.fetchMeetings(from: start, to: end)
                snapshots.append(CalendarProviderSnapshot(provider: provider.name, meetings: meetings))
            } catch {
                failures.append(CalendarSyncFailure(provider: provider.name, message: error.localizedDescription))
            }
        }
        return CalendarSyncReport(successfulSnapshots: snapshots, failures: failures)
    }

    public func sync(from start: Date, to end: Date) async throws -> [Meeting] {
        let report = await syncReport(from: start, to: end)
        if report.successfulProviderCount == 0, let failure = report.failures.first {
            throw CalendarProviderError.api("\(failure.provider): \(failure.message)")
        }
        return report.meetings
    }
}

private func sortedUniqueMeetings(_ meetings: [Meeting]) -> [Meeting] {
    var unique: [String: Meeting] = [:]
    for meeting in meetings { unique[meeting.id] = meeting }
    return unique.values.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
}
