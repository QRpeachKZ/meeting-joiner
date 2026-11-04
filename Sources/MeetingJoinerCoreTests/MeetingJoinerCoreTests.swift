import Foundation
import XCTest
@testable import MeetingJoinerCore

final class GoogleOAuthDesktopClientConfigurationTests: XCTestCase {
    private let validConfiguration = Data(#"{"installed":{"client_id":"12345-synthetic.apps.googleusercontent.com","client_secret":"synthetic-test-secret"}}"#.utf8)

    func testParsesGoogleDesktopClientConfiguration() throws {
        let configuration = try XCTUnwrap(GoogleOAuthDesktopClientConfiguration(data: validConfiguration))
        XCTAssertEqual(configuration.clientID, "12345-synthetic.apps.googleusercontent.com")
        XCTAssertEqual(configuration.clientSecret, "synthetic-test-secret")
        let renderedConfiguration = configuration.description + configuration.debugDescription
        XCTAssertFalse(renderedConfiguration.contains(configuration.clientID))
        XCTAssertFalse(renderedConfiguration.contains(configuration.clientSecret))
    }

    func testRejectsMalformedOrNonDesktopConfigurations() {
        XCTAssertNil(GoogleOAuthDesktopClientConfiguration(data: Data("not json".utf8)))
        XCTAssertNil(GoogleOAuthDesktopClientConfiguration(data: Data(#"{"web":{"client_id":"12345-synthetic.apps.googleusercontent.com","client_secret":"synthetic-test-secret"}}"#.utf8)))
        XCTAssertNil(GoogleOAuthDesktopClientConfiguration(data: Data(#"{"installed":{"client_id":"not-an-oauth-client","client_secret":"synthetic-test-secret"}}"#.utf8)))
        XCTAssertNil(GoogleOAuthDesktopClientConfiguration(data: Data(#"{"installed":{"client_id":"12345-synthetic.apps.googleusercontent.com"}}"#.utf8)))
    }

    func testDiscoversValidMatchingFileAtProjectRootAndSkipsMalformedCandidate() throws {
        let project = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        try Data("not json".utf8).write(to: project.appendingPathComponent("client_secret-a.json"))
        try validConfiguration.write(to: project.appendingPathComponent("client_secret-b.apps.googleusercontent.com.json"))

        let configuration = try XCTUnwrap(GoogleOAuthDesktopClientConfiguration.discover(inProjectDirectory: project))
        XCTAssertEqual(configuration.clientID, "12345-synthetic.apps.googleusercontent.com")
        XCTAssertEqual(configuration.clientSecret, "synthetic-test-secret")
    }

    func testDoesNotSearchNestedDirectoriesOrUnrelatedFiles() throws {
        let project = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let nested = project.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try validConfiguration.write(to: nested.appendingPathComponent("client_secret-nested.json"))
        try validConfiguration.write(to: project.appendingPathComponent("other.json"))

        XCTAssertNil(GoogleOAuthDesktopClientConfiguration.discover(inProjectDirectory: project))
    }

    func testFindsProjectRootFromAppBundleAncestors() throws {
        let project = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        try Data().write(to: project.appendingPathComponent("Package.swift"))
        let appDirectory = project.appendingPathComponent(".build/MeetingJoinerApp.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)

        XCTAssertEqual(
            GoogleOAuthDesktopClientConfiguration.projectRoot(containingPackageFrom: [appDirectory]),
            project
        )
    }

    func testProjectRootSearchStopsAtFilesystemRoot() {
        XCTAssertNil(
            GoogleOAuthDesktopClientConfiguration.projectRoot(
                containingPackageFrom: [URL(fileURLWithPath: "/", isDirectory: true)]
            )
        )
    }

    func testMissingProjectMarkerAndMissingConfigurationLeaveGoogleUnconfigured() throws {
        let unrelatedDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: unrelatedDirectory) }
        XCTAssertNil(GoogleOAuthDesktopClientConfiguration.projectRoot(containingPackageFrom: [unrelatedDirectory]))
        XCTAssertNil(GoogleOAuthDesktopClientConfiguration.discover(inProjectDirectory: unrelatedDirectory))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

final class ExchangeSettingsTests: XCTestCase {
    func testValidSettingsAndEndpointIncludeConfiguredPortAndEWSPath() throws {
        let settings = ExchangeSettings(serverURL: "https://exchange.example.org", port: 8443, domain: "ACME", username: "alice", syncIntervalMinutes: 15)
        try settings.validate()
        let endpoint = try settings.endpointURL()
        XCTAssertEqual(endpoint.absoluteString, "https://exchange.example.org:8443/EWS/Exchange.asmx")
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

    func testBlankLoginClearsBothPartsAndDisablesExchange() throws {
        for raw in ["", " \t\r\n "] {
            var settings = ExchangeSettings(domain: "MOSCOW", username: "U_M1ABC")
            try settings.setLogin(raw)
            XCTAssertEqual(settings.domain, "")
            XCTAssertEqual(settings.username, "")
            XCTAssertEqual(settings.login, "")
            XCTAssertFalse(CalendarSyncConfiguration(exchange: settings).isExchangeEnabled)
            XCTAssertNil(settings.authorizationHeader(password: "synthetic-password"))
        }
    }

    func testLoginParsesAndTrimsDomainAndUsername() throws {
        for raw in ["MOSCOW\\U_M1ABC", " \tMOSCOW\\U_M1ABC\r\n ", " MOSCOW \t\\ U_M1ABC "] {
            var settings = ExchangeSettings()
            try settings.setLogin(raw)
            XCTAssertEqual(settings.domain, "MOSCOW")
            XCTAssertEqual(settings.username, "U_M1ABC")
            XCTAssertEqual(settings.login, "MOSCOW\\U_M1ABC")
            XCTAssertTrue(CalendarSyncConfiguration(exchange: settings).isExchangeEnabled)
        }
    }

    func testMalformedLoginRejectsAtomicallyWithoutDisablingExchange() {
        let malformed = ["U_M1ABC", "MOSCOW\\", "\\U_M1ABC", "\\", "MOSCOW\\\\U_M1ABC",
                         "MOSCOW\\U_M1ABC\\extra", "MOSCOW\\U_M1ABC\\", " \\ U_M1ABC ", "MOSCOW\\ \n"]
        for original in [ExchangeSettings(domain: "MOSCOW", username: "U_M1ABC"), ExchangeSettings()] {
            for raw in malformed {
                var settings = original
                XCTAssertThrowsError(try settings.setLogin(raw), raw) { error in
                    guard case ExchangeSettingsError.invalidLogin = error else {
                        return XCTFail("Expected explicit invalid login error, got \(error)")
                    }
                    XCTAssertTrue(error.localizedDescription.contains("DOMAIN\\USERNAME"))
                }
                XCTAssertEqual(settings, original)
                XCTAssertEqual(CalendarSyncConfiguration(exchange: settings).isExchangeEnabled,
                               CalendarSyncConfiguration(exchange: original).isExchangeEnabled)
            }
        }
    }

    func testLegacyCodableFieldsRenderCombinedLoginAndRemainCompatible() throws {
        let data = Data(#"{"serverURL":"https://exchange.example.org","port":443,"domain":"MOSCOW","username":"U_M1ABC","syncIntervalMinutes":5,"tlsMode":"systemTrust"}"#.utf8)
        let settings = try JSONDecoder().decode(ExchangeSettings.self, from: data)
        XCTAssertEqual(settings.login, "MOSCOW\\U_M1ABC")
        let encoded = try JSONEncoder().encode(settings)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(fields["domain"] as? String, "MOSCOW")
        XCTAssertEqual(fields["username"] as? String, "U_M1ABC")
        XCTAssertNil(fields["login"])
        XCTAssertEqual(try JSONDecoder().decode(ExchangeSettings.self, from: encoded), settings)
        let legacy = ExchangeSettings(username: "legacy-user")
        XCTAssertEqual(legacy.login, "legacy-user")
        XCTAssertNoThrow(try legacy.validate())
    }

    func testParsedLoginProducesBasicHeaderAndPreservesNoTLSPolicy() throws {
        var settings = ExchangeSettings(serverURL: "https://exchange.example.org")
        try settings.setLogin("MOSCOW\\U_M1ABC")
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(3600)
        let request = try EWSRequestBuilder.makeRequest(settings: settings, password: "synthetic-password", from: start, to: end)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Basic " + Data("MOSCOW\\U_M1ABC:synthetic-password".utf8).base64EncodedString())
        settings.serverURL = "http://exchange.example.org"
        XCTAssertThrowsError(try settings.validate())
        settings.tlsMode = .insecureWarning
        let insecureRequest = try EWSRequestBuilder.makeRequest(settings: settings, password: "do-not-send", from: start, to: end)
        XCTAssertNil(insecureRequest.value(forHTTPHeaderField: "Authorization"))
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

    func testDelayedReminderIncludesOnlyOngoingMeetings() {
        let opener = RecordingOpener()
        let coordinator = ReminderCoordinator(opener: opener)
        let now = Date(timeIntervalSince1970: 20_000)
        let url = URL(string: "https://meet.google.com/abc-defg-hij")!
        let current = Meeting(id: "current", title: "Long meeting", start: now.addingTimeInterval(-7200),
                              end: now.addingTimeInterval(60), conferenceURL: url)
        let ended = Meeting(id: "ended", title: "Ended during sleep", start: now.addingTimeInterval(-7200),
                            end: now.addingTimeInterval(-1), conferenceURL: url)
        let endingNow = Meeting(id: "ending-now", title: "Just ended", start: now.addingTimeInterval(-600),
                                end: now, conferenceURL: url)
        let future = Meeting(id: "future", title: "Upcoming", start: now.addingTimeInterval(1),
                             end: now.addingTimeInterval(600), conferenceURL: url)
        XCTAssertEqual(coordinator.remindersToShow(for: [ended, current, endingNow, future], now: now).map(\.id), [current.id])
        XCTAssertEqual(coordinator.remindersToShow(for: [future], now: future.start).map(\.id), [future.id])
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testDuplicateMeetingsProduceOnlyOneReminderAndSkipBeforeStartPersists() {
        let coordinator = ReminderCoordinator(opener: RecordingOpener())
        let now = Date(timeIntervalSince1970: 20_000)
        let meeting = Meeting(id: "duplicate", title: "Meeting", start: now,
                              end: now.addingTimeInterval(600), conferenceURL: URL(string: "https://zoom.us/j/123"))
        XCTAssertEqual(coordinator.remindersToShow(for: [meeting, meeting], now: now).map(\.id), [meeting.id])
        let skipped = ReminderCoordinator(opener: RecordingOpener())
        skipped.handle(.skip, for: meeting)
        XCTAssertTrue(skipped.remindersToShow(for: [], now: now).isEmpty)
        let restored = ReminderCoordinator(opener: RecordingOpener(), dismissedMeetingIDs: skipped.dismissedMeetingIDs)
        XCTAssertTrue(restored.remindersToShow(for: [meeting], now: now).isEmpty)
    }

    func testInvalidConferenceURLsNeitherRemindNorConnect() {
        let opener = RecordingOpener()
        let coordinator = ReminderCoordinator(opener: opener)
        let now = Date(timeIntervalSince1970: 20_000)
        for value in ["http://meet.google.com/abc", "https://zoom.us.attacker.example/j/123",
                      "https://user:password@zoom.us/j/123", "file:///tmp/conference"] {
            let meeting = Meeting(id: value, title: "Invalid", start: now, end: now.addingTimeInterval(600),
                                  conferenceURL: URL(string: value))
            XCTAssertTrue(coordinator.remindersToShow(for: [meeting], now: now).isEmpty)
            XCTAssertFalse(coordinator.handle(.connect, for: meeting))
        }
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
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
          <s:Body><m:GetItemResponse><m:ResponseMessages><m:GetItemResponseMessage ResponseClass="Success">
            <m:ResponseCode>NoError</m:ResponseCode><m:Items>
              <t:CalendarItem><t:ItemId Id="ews-item-1"/><t:Subject>Planning</t:Subject><t:Start>2025-03-04T10:00:00Z</t:Start><t:End>2025-03-04T10:30:00Z</t:End><t:Location>Join https://teams.microsoft.com/l/meetup-join/abc</t:Location></t:CalendarItem>
            </m:Items>
          </m:GetItemResponseMessage></m:ResponseMessages></m:GetItemResponse></s:Body>
        </s:Envelope>
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

    func testPartialSyncReplacesGoogleSnapshotAndRetainsOnlyUnfinishedFailedExchangeMeetings() async {
        let now = Date(timeIntervalSince1970: 20_000)
        let cancelled = meeting("cancelled", start: now, end: now.addingTimeInterval(600))
        let updated = meeting("updated", start: now, end: now.addingTimeInterval(900))
        let exchange = meeting("opaque-exchange-id", start: now.addingTimeInterval(-60), end: now.addingTimeInterval(600))
        let ended = meeting("ended", start: now.addingTimeInterval(-600), end: now)
        var snapshots = CalendarMeetingSnapshots()
        snapshots.apply(await report([StubProvider(name: "Google Calendar", meetings: [cancelled, updated]),
                                      StubProvider(name: "Exchange (EWS)", meetings: [exchange, ended])]), now: now)
        let partial = await report([StubProvider(name: "Google Calendar", meetings: [updated]),
                                    FailingProvider(name: "Exchange (EWS)")])
        snapshots.apply(partial, now: now)
        XCTAssertEqual(snapshots.meetings.map(\.id), [exchange.id, updated.id])
        XCTAssertEqual(partial.successfulSnapshots.map(\.provider), ["Google Calendar"])
    }

    func testSuccessfulEmptySnapshotClearsOnlyThatProvider() async {
        let now = Date(timeIntervalSince1970: 20_000)
        let google = meeting("opaque-google-id", start: now, end: now.addingTimeInterval(600))
        let exchange = meeting("opaque-exchange-id", start: now, end: now.addingTimeInterval(600))
        var snapshots = CalendarMeetingSnapshots()
        snapshots.apply(await report([StubProvider(name: "Google Calendar", meetings: [google]),
                                      StubProvider(name: "Exchange (EWS)", meetings: [exchange])]), now: now)
        let empty = await report([StubProvider(name: "Google Calendar", meetings: []),
                                  FailingProvider(name: "Exchange (EWS)")])
        XCTAssertEqual(empty.successfulProviderCount, 1)
        XCTAssertEqual(empty.successfulSnapshots.first?.provider, "Google Calendar")
        XCTAssertEqual(empty.successfulSnapshots.first?.meetings, [])
        snapshots.apply(empty, now: now)
        XCTAssertEqual(snapshots.meetings, [exchange])
        snapshots.apply(await report([StubProvider(name: "Exchange (EWS)", meetings: [])]), now: now)
        XCTAssertTrue(snapshots.meetings.isEmpty)
    }

    func testBothFailedProvidersRetainTheirUnfinishedSnapshots() async {
        let now = Date(timeIntervalSince1970: 20_000)
        let google = meeting("google-opaque", start: now, end: now.addingTimeInterval(600))
        let exchange = meeting("exchange-opaque", start: now.addingTimeInterval(60), end: now.addingTimeInterval(600))
        let ended = meeting("ended", start: now.addingTimeInterval(-600), end: now)
        var snapshots = CalendarMeetingSnapshots()
        snapshots.apply(await report([StubProvider(name: "Google Calendar", meetings: [google, ended]),
                                      StubProvider(name: "Exchange (EWS)", meetings: [exchange])]), now: now)
        let failures = await report([FailingProvider(name: "Google Calendar"), FailingProvider(name: "Exchange (EWS)")])
        XCTAssertEqual(failures.successfulProviderCount, 0)
        XCTAssertEqual(failures.failures.count, 2)
        snapshots.apply(failures, now: now)
        XCTAssertEqual(snapshots.meetings, [google, exchange])
    }

    func testExplicitSourceRemovalDoesNotResurrectSnapshotOnFailure() async {
        let now = Date(timeIntervalSince1970: 20_000)
        let google = meeting("opaque", start: now, end: now.addingTimeInterval(600))
        var snapshots = CalendarMeetingSnapshots()
        snapshots.apply(await report([StubProvider(name: "Google Calendar", meetings: [google])]), now: now)
        snapshots.remove(providers: [CalendarSyncConfiguration.googleProviderName])
        snapshots.apply(await report([FailingProvider(name: "Google Calendar")]), now: now)
        XCTAssertTrue(snapshots.meetings.isEmpty)
    }

    func testSnapshotReducerDeduplicatesIDsAndUsesReplacementValues() async {
        let now = Date(timeIntervalSince1970: 20_000)
        let original = meeting("same-id", start: now, end: now.addingTimeInterval(600))
        var updated = original
        updated.title = "Updated"
        var snapshots = CalendarMeetingSnapshots()
        snapshots.apply(await report([StubProvider(name: "Google Calendar", meetings: [original, original])]), now: now)
        XCTAssertEqual(snapshots.meetings, [original])
        snapshots.apply(await report([StubProvider(name: "Google Calendar", meetings: [updated])]), now: now)
        XCTAssertEqual(snapshots.meetings, [updated])
    }

    func testFreshSnapshotsWinDuplicateIDsOverRetainedFailedProvider() async {
        let now = Date(timeIntervalSince1970: 20_000)
        let original = meeting("shared-id", start: now, end: now.addingTimeInterval(600))
        var fresh = original
        fresh.title = "Fresh"
        var snapshots = CalendarMeetingSnapshots()
        snapshots.apply(await report([StubProvider(name: "Google Calendar", meetings: [original]),
                                      StubProvider(name: "Exchange (EWS)", meetings: [original])]), now: now)
        snapshots.apply(await report([StubProvider(name: "Google Calendar", meetings: [fresh]),
                                      FailingProvider(name: "Exchange (EWS)")]), now: now)
        XCTAssertEqual(snapshots.meetings, [fresh])
        let full = await report([StubProvider(name: "Google Calendar", meetings: [fresh]),
                                 StubProvider(name: "Exchange (EWS)", meetings: [original])])
        snapshots.apply(full, now: now)
        XCTAssertEqual(snapshots.meetings, full.meetings)
    }

    func testSkipSurvivesEmptyReportsAndReturningMeeting() async {
        let now = Date(timeIntervalSince1970: 20_000)
        let skipped = meeting("skipped", start: now, end: now.addingTimeInterval(600))
        let coordinator = ReminderCoordinator(opener: NoOpOpener())
        coordinator.handle(.skip, for: skipped)
        var snapshots = CalendarMeetingSnapshots()
        for providers: [any MeetingCalendarProvider] in [
            [StubProvider(name: "Google Calendar", meetings: [])],
            [FailingProvider(name: "Google Calendar")],
            [StubProvider(name: "Google Calendar", meetings: [skipped])]
        ] {
            snapshots.apply(await report(providers), now: now)
            XCTAssertTrue(coordinator.remindersToShow(for: snapshots.meetings, now: now).isEmpty)
        }
        XCTAssertEqual(coordinator.dismissedMeetingIDs, [skipped.id])
        let restored = ReminderCoordinator(opener: NoOpOpener(), dismissedMeetingIDs: coordinator.dismissedMeetingIDs)
        XCTAssertTrue(restored.remindersToShow(for: snapshots.meetings, now: now).isEmpty)
    }

    private func meeting(_ id: String, start: Date, end: Date) -> Meeting {
        Meeting(id: id, title: id, start: start, end: end, conferenceURL: URL(string: "https://zoom.us/j/123"))
    }

    private func report(_ providers: [any MeetingCalendarProvider]) async -> CalendarSyncReport {
        await CalendarSyncService(providers: providers).syncReport(from: .distantPast, to: .distantFuture)
    }

    private struct NoOpOpener: ConferenceURLOpening {
        func open(_ url: URL) { XCTFail("Reminders must not auto-connect") }
    }

    private struct StubProvider: MeetingCalendarProvider {
        var name = "Stub"
        let meetings: [Meeting]
        func fetchMeetings(from start: Date, to end: Date) async throws -> [Meeting] { meetings }
    }

    private struct FailingProvider: MeetingCalendarProvider {
        var name = "Unavailable"
        func fetchMeetings(from start: Date, to end: Date) async throws -> [Meeting] {
            throw CalendarProviderError.api("temporarily unavailable")
        }
    }
}

final class CalendarSyncConfigurationTests: XCTestCase {
    func testGoogleOnlySettingsValidateIntervalBeforeExchangeFields() throws {
        var exchange = ExchangeSettings(serverURL: "not a URL", port: 0, syncIntervalMinutes: 0)
        try exchange.setLogin(" \n ")
        XCTAssertFalse(makeConfiguration(exchange).isExchangeEnabled)
        for interval in [0, 1441, Int.max] {
            exchange.syncIntervalMinutes = interval
            let configuration = makeConfiguration(exchange)
            XCTAssertThrowsError(try configuration.validate()) { error in
                guard case ExchangeSettingsError.invalidSyncInterval = error else {
                    return XCTFail("Expected interval validation first, got \(error)")
                }
            }
        }
        for interval in [1, 1440] {
            exchange.syncIntervalMinutes = interval
            XCTAssertNoThrow(try makeConfiguration(exchange).validate())
        }
        try exchange.setLogin("MOSCOW\\U_M1ABC")
        XCTAssertTrue(makeConfiguration(exchange).isExchangeEnabled)
        XCTAssertThrowsError(try makeConfiguration(exchange).validate())
    }

    func testSavedSnapshotAndDraftAreUnaffectedByCandidateLoginParsing() throws {
        var draft = ExchangeSettings(domain: "MOSCOW", username: "U_M1ABC")
        let saved = makeConfiguration(draft)
        let loginDraft = " NEWDOMAIN\\another-user \n"
        var candidateSettings = draft
        try candidateSettings.setLogin(loginDraft)
        let candidate = makeConfiguration(candidateSettings)
        XCTAssertEqual(candidate.exchange.login, "NEWDOMAIN\\another-user")
        XCTAssertEqual(draft.login, "MOSCOW\\U_M1ABC")
        XCTAssertEqual(saved.exchange.login, "MOSCOW\\U_M1ABC")
        XCTAssertEqual(loginDraft, " NEWDOMAIN\\another-user \n")
        draft.syncIntervalMinutes = 0
        XCTAssertEqual(saved.exchange.syncIntervalMinutes, 5)
        XCTAssertNoThrow(try saved.validate())
        XCTAssertNoThrow(try candidate.validate())
        XCTAssertThrowsError(try makeConfiguration(draft).validate())
    }

    func testSourceChangesAreDistinctFromScheduleAndCredentials() throws {
        let original = makeConfiguration(ExchangeSettings(domain: "MOSCOW", username: "U_M1ABC"))
        var exchange = original.exchange
        exchange.syncIntervalMinutes = 20
        exchange.clientIdentityLabel = "updated identity"
        exchange.tlsMode = .customCA
        exchange.customCALabel = "updated CA"
        XCTAssertTrue(makeConfiguration(exchange).changedSources(from: original).isEmpty)
        for update: (inout ExchangeSettings) throws -> Void in [
            { try $0.setLogin("") },
            { try $0.setLogin("MOSCOW\\other-user") },
            { try $0.setLogin("OTHER\\U_M1ABC") },
            { $0.serverURL = "https://new.example.org" },
            { $0.port = 8443 }
        ] {
            exchange = original.exchange
            try update(&exchange)
            XCTAssertEqual(makeConfiguration(exchange).changedSources(from: original), [CalendarSyncConfiguration.exchangeProviderName])
        }
    }

    func testSavingExchangeChangesPreservesGoogleCache() throws {
        let previous = makeConfiguration(ExchangeSettings(domain: "MOSCOW", username: "U_M1ABC"))
        XCTAssertTrue(previous.changedSources(from: previous).isEmpty)
        var exchange = previous.exchange
        try exchange.setLogin("MOSCOW\\other-user")
        let changed = makeConfiguration(exchange).changedSources(from: previous)
        let now = Date()
        let google = Meeting(id: "google:cached", title: "Google", start: now, end: now.addingTimeInterval(600))
        let ews = Meeting(id: "ews:cached", title: "Exchange", start: now, end: now.addingTimeInterval(600))
        var snapshots = CalendarMeetingSnapshots()
        snapshots.apply(CalendarSyncReport(successfulSnapshots: [
            CalendarProviderSnapshot(provider: CalendarSyncConfiguration.googleProviderName, meetings: [google]),
            CalendarProviderSnapshot(provider: CalendarSyncConfiguration.exchangeProviderName, meetings: [ews])
        ], failures: []), now: now)
        snapshots.remove(providers: changed)
        XCTAssertEqual(snapshots.meetings, [google])
    }

    private func makeConfiguration(_ exchange: ExchangeSettings) -> CalendarSyncConfiguration {
        CalendarSyncConfiguration(exchange: exchange)
    }
}

final class CalendarSyncFlightTests: XCTestCase {
    func testConcurrentRequestsCoalesceIntoOneRerun() throws {
        var flight = CalendarSyncFlight()
        let revision = try XCTUnwrap(flight.begin())
        for _ in 0..<20 { XCTAssertNil(flight.begin()) }
        XCTAssertEqual(flight.finish(), revision)
        XCTAssertNil(flight.finish())
        XCTAssertEqual(flight.begin(), revision)
        XCTAssertNil(flight.finish())
    }

    func testSaveRejectsOldResultAndRerunsOnlyLatestRevision() throws {
        var flight = CalendarSyncFlight()
        let oldRevision = try XCTUnwrap(flight.begin())
        flight.configurationDidChange()
        flight.configurationDidChange()
        XCTAssertFalse(flight.isCurrent(oldRevision))
        XCTAssertNil(flight.begin())
        let nextRevision = try XCTUnwrap(flight.finish())
        XCTAssertTrue(flight.isCurrent(nextRevision))
        XCTAssertNotEqual(nextRevision, oldRevision)
        XCTAssertNil(flight.finish())
    }

    func testIdleSaveDoesNotQueueAnExtraSync() throws {
        var flight = CalendarSyncFlight()
        flight.configurationDidChange()
        let revision = try XCTUnwrap(flight.begin())
        XCTAssertTrue(flight.isCurrent(revision))
        XCTAssertNil(flight.finish())
    }
}
