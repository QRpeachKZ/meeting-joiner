import Foundation
import XCTest
@testable import MeetingJoinerCore

final class ExchangeSettingsTests: XCTestCase {
    func testValidSettingsAndEndpointIncludeConfiguredPortAndEWSPath() throws {
        let settings = ExchangeSettings(serverURL: "https://exchange.example.org", port: 8443, domain: "ACME", username: "alice", syncIntervalMinutes: 15)
        try settings.validate()
        XCTAssertEqual(settings.endpointURL().absoluteString, "https://exchange.example.org:8443/EWS/Exchange.asmx")
    }

    func testPortAndSyncIntervalBoundsAreValidated() {
        var settings = ExchangeSettings(port: 0)
        XCTAssertThrowsError(try settings.validate())
        settings.port = 65536
        XCTAssertThrowsError(try settings.validate())
        settings.port = 443
        settings.syncIntervalMinutes = 0
        XCTAssertThrowsError(try settings.validate())
        settings.syncIntervalMinutes = 1441
        XCTAssertThrowsError(try settings.validate())
    }

    func testNoTLSRequiresExplicitHTTPAndNeverSendsPassword() throws {
        let settings = ExchangeSettings(serverURL: "http://exchange.example.org", port: 8080, domain: "ACME", username: "alice", tlsMode: .insecureWarning)
        try settings.validate()
        XCTAssertNotNil(settings.securityWarning)
        let request = try EWSRequestBuilder.makeRequest(settings: settings, password: "do-not-send", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 3600))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(settings.authorizationHeader(password: "do-not-send"))
        XCTAssertEqual(request.url?.scheme, "http")
    }

    func testHTTPSPasswordAuthenticationUsesDomainAndUsername() {
        let settings = ExchangeSettings(serverURL: "https://exchange.example.org", domain: "ACME", username: "alice")
        XCTAssertEqual(settings.authorizationHeader(password: "secret"), "Basic " + Data("ACME\\alice:secret".utf8).base64EncodedString())
    }

    func testCustomCARequiresAKeychainCertificateLabel() {
        var settings = ExchangeSettings(tlsMode: .customCA)
        XCTAssertThrowsError(try settings.validate())
        settings.customCALabel = "Meeting Joiner Exchange CA"
        XCTAssertNoThrow(try settings.validate())
    }

    func testSyncIntervalIsRetainedAsTheConfiguredSchedule() throws {
        let settings = ExchangeSettings(syncIntervalMinutes: 23)
        try settings.validate()
        XCTAssertEqual(settings.syncIntervalMinutes, 23)
    }

    func testServerURLCannotEmbedCredentialsOrQueryData() {
        XCTAssertThrowsError(try ExchangeSettings(serverURL: "https://user:pass@example.org").validate())
        XCTAssertThrowsError(try ExchangeSettings(serverURL: "https://exchange.example.org?password=value").validate())
    }
}

final class ConferenceURLRecognizerTests: XCTestCase {
    func testRecognizesCommonConferenceURLsAndRejectsLookalikeHosts() {
        XCTAssertEqual(ConferenceURLRecognizer.firstURL(in: "Join https://meet.google.com/abc-defg-hij now")?.host, "meet.google.com")
        XCTAssertEqual(ConferenceURLRecognizer.firstURL(in: "https://acme.zoom.us/j/123")?.host, "acme.zoom.us")
        XCTAssertNil(ConferenceURLRecognizer.firstURL(in: "https://zoom.us.attacker.example/j/123"))
        XCTAssertNil(ConferenceURLRecognizer.firstURL(in: "http://meet.google.com/abc"))
    }
}

final class ReminderCoordinatorTests: XCTestCase {
    func testMeetingStartShowsReminderOnceAndSkipDismissesIt() throws {
        let opener = RecordingOpener()
        let coordinator = ReminderCoordinator(opener: opener)
        let now = Date(timeIntervalSince1970: 10_000)
        let meeting = Meeting(id: "google:event-1", title: "Standup", start: now, end: now.addingTimeInterval(1800), conferenceURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(coordinator.remindersToShow(for: [meeting], now: now).map(\.id), [meeting.id])
        XCTAssertTrue(coordinator.remindersToShow(for: [meeting], now: now).isEmpty)
        XCTAssertTrue(coordinator.handle(.skip, for: meeting))
        XCTAssertTrue(coordinator.remindersToShow(for: [meeting], now: now.addingTimeInterval(1)).isEmpty)
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testMeetingWithoutAConferenceURLDoesNotProduceAConnectReminder() {
        let coordinator = ReminderCoordinator(opener: RecordingOpener())
        let now = Date()
        let meeting = Meeting(id: "no-link", title: "In person", start: now, end: now.addingTimeInterval(600))
        XCTAssertTrue(coordinator.remindersToShow(for: [meeting], now: now).isEmpty)
    }

    func testConferenceURLOpensOnlyAfterConnect() throws {
        let opener = RecordingOpener()
        let coordinator = ReminderCoordinator(opener: opener)
        let meeting = Meeting(id: "ews:event-2", title: "Review", start: Date(), end: Date().addingTimeInterval(600), conferenceURL: URL(string: "https://zoom.us/j/987654"))
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertTrue(coordinator.handle(.connect, for: meeting))
        XCTAssertEqual(opener.opened, [meeting.conferenceURL!])
    }

    func testDismissedMeetingRemainsDismissedWhenCoordinatorIsRestored() {
        let meeting = Meeting(id: "skipped-event", title: "Skipped", start: Date(), end: Date().addingTimeInterval(600), conferenceURL: URL(string: "https://zoom.us/j/123"))
        let restored = ReminderCoordinator(opener: RecordingOpener(), dismissedMeetingIDs: [meeting.id])
        XCTAssertTrue(restored.remindersToShow(for: [meeting], now: meeting.start).isEmpty)
    }

    func testConnectWithoutConferenceURLDoesNotOpenAnything() {
        let opener = RecordingOpener()
        let coordinator = ReminderCoordinator(opener: opener)
        let meeting = Meeting(id: "no-link", title: "In person", start: Date(), end: Date().addingTimeInterval(600))
        XCTAssertFalse(coordinator.handle(.connect, for: meeting))
        XCTAssertTrue(opener.opened.isEmpty)
    }

    private final class RecordingOpener: ConferenceURLOpening, @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        var opened: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
        func open(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    }
}

final class EWSCalendarParserTests: XCTestCase {
    func testParsesNamespacedEWSCalendarItemsAndRecognizesMeetingLink() throws {
        let xml = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body><t:CalendarItem><t:ItemId Id="ews-item-1"/><t:Subject>Planning</t:Subject><t:Start>2025-03-04T10:00:00Z</t:Start><t:End>2025-03-04T10:30:00Z</t:End><t:Location>Join https://teams.microsoft.com/l/meetup-join/abc</t:Location></t:CalendarItem></s:Body></s:Envelope>
        """
        let meetings = try EWSCalendarParser.parse(Data(xml.utf8))
        XCTAssertEqual(meetings.count, 1)
        XCTAssertEqual(meetings[0].id, "ews:ews-item-1")
        XCTAssertEqual(meetings[0].title, "Planning")
        XCTAssertEqual(meetings[0].conferenceURL?.host, "teams.microsoft.com")
    }
}

final class CalendarSyncServiceTests: XCTestCase {
    func testSyncCombinesProvidersDeduplicatesIDsAndSortsMeetings() async throws {
        let later = Meeting(id: "later", title: "Later", start: Date(timeIntervalSince1970: 20), end: Date(timeIntervalSince1970: 30))
        let earlier = Meeting(id: "earlier", title: "Earlier", start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 15))
        let replacement = Meeting(id: "earlier", title: "Updated", start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 16))
        let service = CalendarSyncService(providers: [StubProvider(meetings: [later, earlier]), StubProvider(meetings: [replacement])])
        let result = try await service.sync(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(result.map(\.id), ["earlier", "later"])
        XCTAssertEqual(result.first?.title, "Updated")
    }

    func testSyncReportKeepsHealthyProviderResultsWhenAnotherProviderFails() async {
        let meeting = Meeting(id: "google:healthy", title: "Healthy", start: Date(), end: Date().addingTimeInterval(600))
        let service = CalendarSyncService(providers: [StubProvider(meetings: [meeting]), FailingProvider()])
        let report = await service.syncReport(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(report.meetings.map(\.id), [meeting.id])
        XCTAssertEqual(report.successfulProviderCount, 1)
        XCTAssertEqual(report.failures.map(\.provider), ["Unavailable"])
    }

    private struct StubProvider: MeetingCalendarProvider {
        let name = "Stub"
        let meetings: [Meeting]
        func fetchMeetings(from start: Date, to end: Date) async throws -> [Meeting] { meetings }
    }

    private struct FailingProvider: MeetingCalendarProvider {
        let name = "Unavailable"
        func fetchMeetings(from start: Date, to end: Date) async throws -> [Meeting] {
            throw CalendarProviderError.api("temporarily unavailable")
        }
    }
}
