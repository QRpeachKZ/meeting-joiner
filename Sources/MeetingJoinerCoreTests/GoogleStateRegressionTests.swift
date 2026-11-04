import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MeetingJoinerCore

final class GoogleStateRegressionTests: XCTestCase {
    func testRefreshCannotOverwriteNewSignInOrReturnStaleMeetings() async throws {
        let fixture = GoogleHTTPFixture()
        let original = token("A", expired: true)
        let replacement = token("B")
        let store = GoogleMemoryTokenStore(original)
        let task = Task { try await fixture.fetch(store: store) }
        await fulfillment(of: [fixture.refreshRequested], timeout: 3)
        try store.saveToken(replacement)
        try fixture.respondToRefresh()
        await assertStale(task)
        XCTAssertEqual(try store.loadToken(), replacement)
        XCTAssertEqual(store.replaceAttempts, 1)
        XCTAssertEqual(store.successfulReplacements, 0)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testOrdinaryRefreshPersistsTokenAndFetchesMeetings() async throws {
        let fixture = GoogleHTTPFixture()
        let original = token("A", expired: true)
        let store = GoogleMemoryTokenStore(original)
        let task = Task { try await fixture.fetch(store: store) }
        await fulfillment(of: [fixture.refreshRequested], timeout: 3)
        try fixture.respondToRefresh()
        await fulfillment(of: [fixture.eventsRequested], timeout: 3)
        let refreshed = try XCTUnwrap(store.loadToken())
        XCTAssertEqual(refreshed.accessToken, "refreshed-A")
        XCTAssertEqual(refreshed.refreshToken, original.refreshToken)
        XCTAssertGreaterThan(refreshed.expiresAt, Date().addingTimeInterval(3000))
        XCTAssertEqual(fixture.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-A")
        XCTAssertEqual(fixture.requests.last?.url?.path, "/calendar/v3/calendars/primary/events")
        try fixture.respondToEvents()
        let meetings = try await task.value
        XCTAssertEqual(meetings.map(\.id), ["google:synthetic-event"])
        XCTAssertEqual(store.successfulReplacements, 1)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testNewSignInAfterSuccessfulCASRejectsInFlightEvents() async throws {
        let fixture = GoogleHTTPFixture()
        let store = GoogleMemoryTokenStore(token("A", expired: true))
        let task = Task { try await fixture.fetch(store: store) }
        await fulfillment(of: [fixture.refreshRequested], timeout: 3)
        try fixture.respondToRefresh()
        await fulfillment(of: [fixture.eventsRequested], timeout: 3)
        let replacement = token("B")
        try store.saveToken(replacement)
        try fixture.respondToEvents()
        await assertStale(task)
        XCTAssertEqual(try store.loadToken(), replacement)
        XCTAssertEqual(store.successfulReplacements, 1)
    }

    func testNewSignInWithoutRefreshRejectsInFlightEvents() async throws {
        let fixture = GoogleHTTPFixture()
        let store = GoogleMemoryTokenStore(token("A"))
        let task = Task { try await fixture.fetch(store: store) }
        await fulfillment(of: [fixture.eventsRequested], timeout: 3)
        let replacement = token("B")
        try store.saveToken(replacement)
        try fixture.respondToEvents()
        await assertStale(task)
        XCTAssertEqual(try store.loadToken(), replacement)
        XCTAssertEqual(store.replaceAttempts, 0)
    }

    func testCancellationDuringRefreshDoesNotWriteTokenOrFetchEvents() async throws {
        let fixture = GoogleHTTPFixture()
        let original = token("A", expired: true)
        let store = GoogleMemoryTokenStore(original)
        let task = Task { try await fixture.fetch(store: store) }
        await fulfillment(of: [fixture.refreshRequested], timeout: 3)
        task.cancel()
        await assertCancelled(task)
        XCTAssertEqual(try store.loadToken(), original)
        XCTAssertEqual(store.replaceAttempts, 0)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testCancellationDuringEventsDoesNotReturnMeetings() async throws {
        let fixture = GoogleHTTPFixture()
        let original = token("A")
        let store = GoogleMemoryTokenStore(original)
        let task = Task { try await fixture.fetch(store: store) }
        await fulfillment(of: [fixture.eventsRequested], timeout: 3)
        task.cancel()
        await assertCancelled(task)
        XCTAssertEqual(try store.loadToken(), original)
        XCTAssertEqual(store.replaceAttempts, 0)
    }

    private func token(_ account: String, expired: Bool = false) -> GoogleOAuthToken {
        GoogleOAuthToken(accessToken: account, refreshToken: "refresh-\(account)",
                         expiresAt: expired ? .distantPast : .distantFuture)
    }

    private func assertStale(_ task: Task<[Meeting], Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("Stale fetch must fail, not return meetings", file: file, line: line)
        } catch CalendarProviderError.api(let message) {
            XCTAssertEqual(message, "Google authorization changed during sync; discarded stale results.", file: file, line: line)
        } catch {
            XCTFail("Expected explicit stale authorization error, got \(error)", file: file, line: line)
        }
    }

    private func assertCancelled(_ task: Task<[Meeting], Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("Cancelled fetch must not return meetings", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled, file: file, line: line)
        }
    }
}

final class SettingsSecretBatchTests: XCTestCase {
    private let exchange = "exchange.password"
    private let google = "google.client-secret"

    func testSecondWriteFailureRollsBackFirstAfterReadingAllOriginals() {
        let originals = [exchange: Data("old-exchange".utf8), google: Data("old-google".utf8)]
        let store = FakeSettingsSecretStore(originals)
        store.failingWrites = [2]
        XCTAssertThrowsError(try applyChanges(store))
        XCTAssertEqual(store.values, originals)
        XCTAssertEqual(store.operations, ["read:\(exchange)", "read:\(google)",
                                          "write:\(exchange)", "write:\(google)", "write:\(exchange)"])
    }

    func testPreReadFailurePerformsZeroWrites() {
        let originals = [exchange: Data("old-exchange".utf8), google: Data("old-google".utf8)]
        let store = FakeSettingsSecretStore(originals)
        store.failingRead = google
        XCTAssertThrowsError(try applyChanges(store))
        XCTAssertEqual(store.values, originals)
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertEqual(store.operations, ["read:\(exchange)", "read:\(google)"])
    }

    func testRollbackRestoresAbsentValueAndDeletedValue() {
        for original: Data? in [nil, Data("old-exchange".utf8)] {
            let store = FakeSettingsSecretStore([google: Data("old-google".utf8)])
            store.values[exchange] = original
            let originals = store.values
            store.failingWrites = [2]
            let updates = [SettingsSecretUpdate(account: exchange, value: original == nil ? Data("new".utf8) : nil),
                           SettingsSecretUpdate(account: google, value: Data("new-google".utf8))]
            XCTAssertThrowsError(try SettingsSecretBatch.apply(updates, load: store.load, write: store.write))
            XCTAssertEqual(store.values, originals)
        }
    }

    func testRollbackFailureExplicitlyReportsUnrestoredSecrets() {
        let store = FakeSettingsSecretStore([exchange: Data("old-exchange".utf8), google: Data("old-google".utf8)])
        store.failingWrites = [2, 3]
        XCTAssertThrowsError(try applyChanges(store)) { error in
            guard case SettingsSecretBatchError.rollbackFailed = error else {
                return XCTFail("Expected explicit rollback failure")
            }
            XCTAssertTrue(error.localizedDescription.contains("saved secrets may have changed"))
        }
        XCTAssertEqual(store.values[exchange], Data("new-exchange".utf8))
        XCTAssertEqual(store.values[google], Data("old-google".utf8))
    }

    func testSuccessfulBatchReportsChangesAndUpdatesBothSecrets() throws {
        let store = FakeSettingsSecretStore([:])
        XCTAssertTrue(try applyChanges(store))
        XCTAssertEqual(store.values, [exchange: Data("new-exchange".utf8), google: Data("new-google".utf8)])
        XCTAssertEqual(store.operations, ["read:\(exchange)", "read:\(google)", "write:\(exchange)", "write:\(google)"])
    }

    func testNoOpSaveKeepsOAuthRevisionAndDoesNotQueueSync() throws {
        let store = FakeSettingsSecretStore([exchange: Data("new-exchange".utf8)])
        var flight = CalendarSyncFlight()
        let oauthRevision = flight.revision
        XCTAssertEqual(flight.begin(), oauthRevision)
        let configuration = CalendarSyncConfiguration(exchange: ExchangeSettings(domain: "MOSCOW", username: "U_M1ABC"))
        var candidate = configuration.exchange
        try candidate.setLogin(" MOSCOW\\U_M1ABC \n")
        let secretsChanged = try SettingsSecretBatch.apply([
            SettingsSecretUpdate(account: exchange, value: Data("new-exchange".utf8))
        ], load: store.load, write: store.write)
        XCTAssertFalse(secretsChanged)
        XCTAssertFalse(try SettingsSecretBatch.apply([], load: store.load, write: store.write))
        flight.settingsDidSave(from: configuration, to: CalendarSyncConfiguration(exchange: candidate), secretsChanged: secretsChanged)
        XCTAssertTrue(flight.isCurrent(oauthRevision))
        XCTAssertNil(flight.finish())
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertEqual(store.operations, ["read:\(exchange)"])
    }

    func testActualExchangeConfigOrPasswordChangesInvalidateOAuthAndQueueLatestSync() throws {
        let previous = CalendarSyncConfiguration(exchange: ExchangeSettings())
        var exchangeSettings = previous.exchange
        try exchangeSettings.setLogin("MOSCOW\\U_M1ABC")
        let changed = CalendarSyncConfiguration(exchange: exchangeSettings)
        let store = FakeSettingsSecretStore([:])
        let secretsChanged = try SettingsSecretBatch.apply([
            SettingsSecretUpdate(account: exchange, value: Data("new-exchange".utf8))
        ], load: store.load, write: store.write)
        XCTAssertTrue(secretsChanged)
        XCTAssertEqual(store.operations, ["read:\(exchange)", "write:\(exchange)"])
        for (configuration, secrets) in [(previous, secretsChanged), (changed, false)] {
            var flight = CalendarSyncFlight()
            let oauthRevision = try XCTUnwrap(flight.begin())
            flight.settingsDidSave(from: previous, to: configuration, secretsChanged: secrets)
            XCTAssertFalse(flight.isCurrent(oauthRevision))
            XCTAssertEqual(flight.revision, oauthRevision + 1)
            XCTAssertEqual(flight.finish(), flight.revision)
            XCTAssertNil(flight.finish())
        }
    }

    private func applyChanges(_ store: FakeSettingsSecretStore) throws -> Bool {
        try SettingsSecretBatch.apply([SettingsSecretUpdate(account: exchange, value: Data("new-exchange".utf8)),
                                       SettingsSecretUpdate(account: google, value: Data("new-google".utf8))],
                                      load: store.load, write: store.write)
    }
}

private final class FakeSettingsSecretStore {
    var values: [String: Data]
    var failingRead: String?
    var failingWrites = Set<Int>()
    private(set) var operations: [String] = []
    private(set) var writeCount = 0

    init(_ values: [String: Data]) { self.values = values }

    func load(_ account: String) throws -> Data? {
        operations.append("read:\(account)")
        if failingRead == account { throw URLError(.cannotOpenFile) }
        return values[account]
    }

    func write(_ value: Data?, account: String) throws {
        operations.append("write:\(account)")
        writeCount += 1
        if failingWrites.contains(writeCount) { throw URLError(.cannotWriteToFile) }
        values[account] = value
    }
}

private final class GoogleMemoryTokenStore: GoogleTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: GoogleOAuthToken
    private var attempts = 0
    private var replacements = 0
    private var saves = 0

    init(_ token: GoogleOAuthToken) { self.token = token }

    var replaceAttempts: Int { lock.withLock { attempts } }
    var successfulReplacements: Int { lock.withLock { replacements } }
    var saveCount: Int { lock.withLock { saves } }

    func loadToken() throws -> GoogleOAuthToken? { lock.withLock { token } }

    func saveToken(_ token: GoogleOAuthToken) throws {
        lock.withLock { self.token = token; saves += 1 }
    }

    func replaceToken(_ token: GoogleOAuthToken, ifCurrent current: GoogleOAuthToken) throws -> Bool {
        lock.withLock {
            attempts += 1
            guard self.token == current else { return false }
            self.token = token
            replacements += 1
            return true
        }
    }
}

private final class GoogleHTTPFixture: @unchecked Sendable {
    let refreshRequested = XCTestExpectation(description: "Refresh in flight")
    let eventsRequested = XCTestExpectation(description: "Events in flight")
    private let lock = NSLock()
    private var pending: [GoogleStateURLProtocol] = []
    private let identifier = UUID().uuidString
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleStateURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Google-Test": identifier]
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
        GoogleStateURLProtocol.register(identifier) { [weak self] request in
            guard let self else { return }
            self.lock.withLock { self.pending.append(request) }
            if request.request.url?.host == "oauth2.googleapis.com" {
                self.refreshRequested.fulfill()
            } else {
                self.eventsRequested.fulfill()
            }
        }
    }

    deinit {
        session.invalidateAndCancel()
        GoogleStateURLProtocol.unregister(identifier)
    }

    var requests: [URLRequest] { lock.withLock { pending.map(\.request) } }

    func fetch(store: GoogleMemoryTokenStore) async throws -> [Meeting] {
        try await GoogleCalendarProvider(clientID: "synthetic-client", tokenStore: store, session: session)
            .fetchMeetings(from: .distantPast, to: .distantFuture)
    }

    func respondToRefresh() throws {
        try respond(host: "oauth2.googleapis.com", json: #"{"access_token":"refreshed-A","expires_in":3600}"#)
    }

    func respondToEvents() throws {
        try respond(host: "www.googleapis.com", json: #"{"items":[{"id":"synthetic-event","summary":"Synthetic","start":{"dateTime":"2026-10-25T10:00:00Z"},"end":{"dateTime":"2026-10-25T11:00:00Z"}}]}"#)
    }

    private func respond(host: String, json: String) throws {
        let request = try XCTUnwrap(lock.withLock { pending.last { $0.request.url?.host == host } })
        request.respond(json: json)
    }
}

private final class GoogleStateURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handlers: [String: (GoogleStateURLProtocol) -> Void] = [:]
    private let stateLock = NSLock()
    private var stopped = false

    static func register(_ identifier: String, handler: @escaping (GoogleStateURLProtocol) -> Void) {
        lock.withLock { handlers[identifier] = handler }
    }

    static func unregister(_ identifier: String) {
        _ = lock.withLock { handlers.removeValue(forKey: identifier) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handlers[request.value(forHTTPHeaderField: "X-Google-Test") ?? ""] }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        handler(self)
    }

    override func stopLoading() { stateLock.withLock { stopped = true } }

    func respond(json: String) {
        guard !stateLock.withLock({ stopped }) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
