import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import MeetingJoinerCore

final class CachedGoogleTokenStoreTests: XCTestCase {
    func testMultipleLoadsReadPersistenceOnce() throws {
        let original = token("original")
        let persistence = FakeGoogleTokenPersistence(original)
        let store = persistence.makeStore()

        for _ in 0..<10 {
            XCTAssertEqual(try store.loadToken(), original)
        }
        XCTAssertEqual(persistence.readCount, 1)
        XCTAssertEqual(persistence.writeCount, 0)
    }

    func testMissingTokenIsCached() throws {
        let persistence = FakeGoogleTokenPersistence(nil)
        let store = persistence.makeStore()

        for _ in 0..<10 {
            XCTAssertNil(try store.loadToken())
        }
        XCTAssertFalse(try store.replaceToken(token("replacement"), ifCurrent: token("missing")))
        XCTAssertEqual(persistence.readCount, 1)
        XCTAssertEqual(persistence.writeCount, 0)
    }

    func testFirstLoadErrorIsRetried() throws {
        let original = token("original")
        let persistence = FakeGoogleTokenPersistence(original, failingReads: [1])
        let store = persistence.makeStore()

        XCTAssertThrowsError(try store.loadToken())
        XCTAssertEqual(try store.loadToken(), original)
        XCTAssertEqual(try store.loadToken(), original)
        XCTAssertEqual(persistence.readCount, 2)
        XCTAssertEqual(persistence.writeCount, 0)
    }

    func testSaveBeforeLoadDoesNotReadPersistence() throws {
        let replacement = token("replacement")
        let persistence = FakeGoogleTokenPersistence(token("original"))
        let store = persistence.makeStore()

        try store.saveToken(replacement)
        XCTAssertEqual(try store.loadToken(), replacement)
        XCTAssertEqual(persistence.storedToken, replacement)
        XCTAssertEqual(persistence.readCount, 0)
        XCTAssertEqual(persistence.writeCount, 1)
    }

    func testFailedSaveDoesNotAlterCachedTokenOrCachedMissingToken() throws {
        for original: GoogleOAuthToken? in [token("original"), nil] {
            let persistence = FakeGoogleTokenPersistence(original, failingWrites: [1])
            let store = persistence.makeStore()
            XCTAssertEqual(try store.loadToken(), original)

            XCTAssertThrowsError(try store.saveToken(token("replacement")))
            XCTAssertEqual(try store.loadToken(), original)
            XCTAssertEqual(persistence.storedToken, original)
            XCTAssertEqual(persistence.readCount, 1)
            XCTAssertEqual(persistence.writeCount, 1)
        }
    }

    func testFailedSaveBeforeLoadLeavesCacheUnloaded() throws {
        let original = token("original")
        let persistence = FakeGoogleTokenPersistence(original, failingWrites: [1])
        let store = persistence.makeStore()

        XCTAssertThrowsError(try store.saveToken(token("replacement")))
        XCTAssertEqual(persistence.readCount, 0)
        XCTAssertEqual(try store.loadToken(), original)
        XCTAssertEqual(try store.loadToken(), original)
        XCTAssertEqual(persistence.storedToken, original)
        XCTAssertEqual(persistence.readCount, 1)
        XCTAssertEqual(persistence.writeCount, 1)
    }

    func testRepeatedCASWithUnchangedRefreshTokenOnlyUpdatesMemoryAndRejectsStaleComparison() throws {
        let original = token("original", refreshToken: "R")
        let persistence = FakeGoogleTokenPersistence(original, failingWrites: [1])
        let store = persistence.makeStore()
        var current = original

        for index in 0..<10 {
            let replacement = token("refreshed-\(index)", refreshToken: "R")
            XCTAssertTrue(try store.replaceToken(replacement, ifCurrent: current))
            XCTAssertFalse(try store.replaceToken(token("stale", refreshToken: "R"), ifCurrent: current))
            XCTAssertFalse(try store.replaceToken(token("stale-rotation", refreshToken: "S"), ifCurrent: original))
            XCTAssertEqual(try store.loadToken(), replacement)
            XCTAssertEqual(persistence.storedToken, original)
            XCTAssertEqual(persistence.readCount, 1)
            XCTAssertEqual(persistence.writeCount, 0)
            current = replacement
        }
    }

    func testCASPersistsRotatedRefreshTokenAndNewCacheLoadsIt() throws {
        let original = token("original", refreshToken: "R")
        let refreshed = token("refreshed", refreshToken: "R")
        let replacement = token("replacement", refreshToken: "S")
        let persistence = FakeGoogleTokenPersistence(original)
        let store = persistence.makeStore()

        XCTAssertTrue(try store.replaceToken(refreshed, ifCurrent: original))
        XCTAssertEqual(persistence.writeCount, 0)
        XCTAssertTrue(try store.replaceToken(replacement, ifCurrent: refreshed))
        XCTAssertFalse(try store.replaceToken(token("stale-refresh"), ifCurrent: original))
        XCTAssertFalse(try store.replaceToken(token("stale-refresh"), ifCurrent: refreshed))
        XCTAssertEqual(try store.loadToken(), replacement)
        XCTAssertEqual(persistence.storedToken, replacement)
        XCTAssertEqual(persistence.readCount, 1)
        XCTAssertEqual(persistence.writeCount, 1)

        let restartedStore = persistence.makeStore()
        XCTAssertEqual(try restartedStore.loadToken(), replacement)
        XCTAssertEqual(persistence.readCount, 2)
        XCTAssertEqual(persistence.writeCount, 1)
    }

    func testCASPersistsWhenEitherRefreshTokenIsMissingOrEmpty() throws {
        for oldRefresh: String? in [nil, "", "R"] {
            for newRefresh: String? in [nil, "", "R"] {
                if oldRefresh == "R", newRefresh == "R" { continue }
                let original = token("original", refreshToken: oldRefresh)
                let replacement = token("replacement", refreshToken: newRefresh)
                let persistence = FakeGoogleTokenPersistence(original)
                let store = persistence.makeStore()

                XCTAssertTrue(try store.replaceToken(replacement, ifCurrent: original))
                XCTAssertEqual(try store.loadToken(), replacement)
                XCTAssertEqual(persistence.storedToken, replacement)
                XCTAssertEqual(persistence.readCount, 1)
                XCTAssertEqual(persistence.writeCount, 1)
            }
        }
    }

    func testExplicitSaveAlwaysPersistsEvenWithUnchangedRefreshToken() throws {
        let original = token("original", refreshToken: "R")
        let refreshed = token("refreshed", refreshToken: "R")
        let persistence = FakeGoogleTokenPersistence(original)
        let store = persistence.makeStore()
        XCTAssertTrue(try store.replaceToken(refreshed, ifCurrent: original))
        XCTAssertEqual(persistence.writeCount, 0)

        for expectedWrites in 1...2 {
            try store.saveToken(refreshed)
            XCTAssertEqual(try store.loadToken(), refreshed)
            XCTAssertEqual(persistence.storedToken, refreshed)
            XCTAssertEqual(persistence.readCount, 1)
            XCTAssertEqual(persistence.writeCount, expectedWrites)
        }
    }

    func testCASRejectsInitiallyMismatchedTokenWithoutWriting() throws {
        let original = token("original")
        let persistence = FakeGoogleTokenPersistence(original)
        let store = persistence.makeStore()

        XCTAssertFalse(try store.replaceToken(token("replacement"), ifCurrent: token("stale")))
        XCTAssertEqual(try store.loadToken(), original)
        XCTAssertEqual(persistence.storedToken, original)
        XCTAssertEqual(persistence.readCount, 1)
        XCTAssertEqual(persistence.writeCount, 0)
    }

    func testFailedCASRotationWriteKeepsCachedTokenAndAllowsRetry() throws {
        let original = token("original", refreshToken: "R")
        let refreshed = token("refreshed", refreshToken: "R")
        let replacement = token("replacement", refreshToken: "S")
        let persistence = FakeGoogleTokenPersistence(original, failingWrites: [1])
        let store = persistence.makeStore()
        XCTAssertTrue(try store.replaceToken(refreshed, ifCurrent: original))

        XCTAssertThrowsError(try store.replaceToken(replacement, ifCurrent: refreshed))
        XCTAssertEqual(try store.loadToken(), refreshed)
        XCTAssertEqual(persistence.storedToken, original)
        XCTAssertEqual(persistence.writeCount, 1)
        XCTAssertFalse(try store.replaceToken(replacement, ifCurrent: original))
        XCTAssertEqual(persistence.writeCount, 1)
        XCTAssertTrue(try store.replaceToken(replacement, ifCurrent: refreshed))
        XCTAssertEqual(try store.loadToken(), replacement)
        XCTAssertEqual(persistence.storedToken, replacement)
        XCTAssertEqual(persistence.readCount, 1)
        XCTAssertEqual(persistence.writeCount, 2)
    }

    func testFailedCASLoadIsRetriedWithoutWriting() throws {
        let original = token("original")
        let replacement = token("replacement")
        let persistence = FakeGoogleTokenPersistence(original, failingReads: [1])
        let store = persistence.makeStore()

        XCTAssertThrowsError(try store.replaceToken(replacement, ifCurrent: original))
        XCTAssertEqual(persistence.writeCount, 0)
        XCTAssertTrue(try store.replaceToken(replacement, ifCurrent: original))
        XCTAssertEqual(try store.loadToken(), replacement)
        XCTAssertEqual(persistence.readCount, 2)
        XCTAssertEqual(persistence.writeCount, 1)
    }

    func testDifferentReadAndSaveClientsShareCache() throws {
        let original = token("original")
        let replacement = token("replacement")
        let refreshed = token("refreshed", refreshToken: replacement.refreshToken)
        let persistence = FakeGoogleTokenPersistence(original)
        let cache = persistence.makeStore()
        let reader = CachedTokenClient(cache: cache)
        let writer = CachedTokenClient(cache: cache)

        XCTAssertEqual(try reader.loadToken(), original)
        try writer.saveToken(replacement)
        XCTAssertEqual(try reader.loadToken(), replacement)
        XCTAssertFalse(try reader.replaceToken(token("stale-refresh"), ifCurrent: original))
        XCTAssertTrue(try reader.replaceToken(refreshed, ifCurrent: replacement))
        XCTAssertEqual(try writer.loadToken(), refreshed)
        XCTAssertEqual(persistence.storedToken, replacement)
        XCTAssertEqual(persistence.readCount, 1)
        XCTAssertEqual(persistence.writeCount, 1)
    }

    func testConcurrentCASHasOnlyOneWinnerWithOrWithoutRotation() async throws {
        for rotatesRefreshToken in [false, true] {
            let original = token("original", refreshToken: "R")
            let candidates = (0..<32).map {
                token("replacement-\($0)", refreshToken: rotatesRefreshToken ? "S" : "R")
            }
            let persistence = FakeGoogleTokenPersistence(original)
            let store = persistence.makeStore()

            let winners = try await withThrowingTaskGroup(of: Bool.self) { group in
                for candidate in candidates {
                    group.addTask {
                        try store.replaceToken(candidate, ifCurrent: original)
                    }
                }
                var count = 0
                for try await replaced in group {
                    if replaced { count += 1 }
                }
                return count
            }

            XCTAssertEqual(winners, 1)
            let winner = try XCTUnwrap(store.loadToken())
            XCTAssertTrue(candidates.contains(winner))
            XCTAssertEqual(persistence.storedToken, rotatesRefreshToken ? winner : original)
            XCTAssertEqual(persistence.readCount, 1)
            XCTAssertEqual(persistence.writeCount, rotatesRefreshToken ? 1 : 0)
        }
    }

    func testNewCacheInstanceReadsPersistedUpdatedToken() throws {
        let original = token("original")
        let replacement = token("replacement")
        let persistence = FakeGoogleTokenPersistence(original)
        let store = persistence.makeStore()
        XCTAssertEqual(try store.loadToken(), original)
        try store.saveToken(replacement)

        let restartedStore = persistence.makeStore()
        XCTAssertEqual(try restartedStore.loadToken(), replacement)
        XCTAssertEqual(try restartedStore.loadToken(), replacement)
        XCTAssertEqual(persistence.readCount, 2)
        XCTAssertEqual(persistence.writeCount, 1)
    }

    func testProviderRefreshReusesMemoryAndRefreshesPersistedExpiredSnapshotAfterRestart() async throws {
        let original = GoogleOAuthToken(accessToken: "expired-access", refreshToken: "R", expiresAt: .distantPast)
        let persistence = FakeGoogleTokenPersistence(original)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CachedGoogleRefreshURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let store = persistence.makeStore()
        let provider = GoogleCalendarProvider(clientID: "synthetic-client", tokenStore: store, session: session)

        let firstMeetings = try await provider.fetchMeetings(from: .distantPast, to: .distantFuture)
        let refreshed = try XCTUnwrap(store.loadToken())
        XCTAssertNotEqual(refreshed.accessToken, original.accessToken)
        XCTAssertEqual(refreshed.refreshToken, "R")
        XCTAssertGreaterThan(refreshed.expiresAt, Date().addingTimeInterval(3000))
        XCTAssertEqual(firstMeetings.map(\.id), ["google:\(refreshed.accessToken)"])
        XCTAssertEqual(persistence.readCount, 1)
        XCTAssertEqual(persistence.writeCount, 0)

        let secondMeetings = try await provider.fetchMeetings(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(secondMeetings.map(\.id), firstMeetings.map(\.id))
        XCTAssertEqual(try store.loadToken(), refreshed)
        XCTAssertEqual(persistence.storedToken, original)
        XCTAssertEqual(persistence.readCount, 1)
        XCTAssertEqual(persistence.writeCount, 0)

        let restartedStore = persistence.makeStore()
        XCTAssertEqual(try restartedStore.loadToken(), original)
        let restartedProvider = GoogleCalendarProvider(clientID: "synthetic-client", tokenStore: restartedStore, session: session)
        let restartedMeetings = try await restartedProvider.fetchMeetings(from: .distantPast, to: .distantFuture)
        let refreshedAgain = try XCTUnwrap(restartedStore.loadToken())
        XCTAssertNotEqual(refreshedAgain.accessToken, original.accessToken)
        XCTAssertNotEqual(refreshedAgain.accessToken, refreshed.accessToken)
        XCTAssertEqual(refreshedAgain.refreshToken, "R")
        XCTAssertGreaterThan(refreshedAgain.expiresAt, Date().addingTimeInterval(3000))
        XCTAssertEqual(restartedMeetings.map(\.id), ["google:\(refreshedAgain.accessToken)"])
        XCTAssertEqual(try store.loadToken(), refreshed)
        XCTAssertEqual(persistence.storedToken, original)
        XCTAssertEqual(persistence.readCount, 2)
        XCTAssertEqual(persistence.writeCount, 0)
    }

    private func token(_ value: String) -> GoogleOAuthToken {
        token(value, refreshToken: "refresh-\(value)")
    }

    private func token(_ value: String, refreshToken: String?) -> GoogleOAuthToken {
        GoogleOAuthToken(accessToken: value, refreshToken: refreshToken, expiresAt: .distantFuture)
    }
}

private struct CachedTokenClient: GoogleTokenStoring {
    let cache: CachedGoogleTokenStore

    func loadToken() throws -> GoogleOAuthToken? { try cache.loadToken() }
    func saveToken(_ token: GoogleOAuthToken) throws { try cache.saveToken(token) }
    func replaceToken(_ token: GoogleOAuthToken, ifCurrent current: GoogleOAuthToken) throws -> Bool {
        try cache.replaceToken(token, ifCurrent: current)
    }
}

private final class FakeGoogleTokenPersistence: @unchecked Sendable {
    private enum Failure: Error { case read, write }

    private let lock = NSLock()
    private let failingReads: Set<Int>
    private let failingWrites: Set<Int>
    private var token: GoogleOAuthToken?
    private var reads = 0
    private var writes = 0

    init(_ token: GoogleOAuthToken?, failingReads: Set<Int> = [], failingWrites: Set<Int> = []) {
        self.token = token
        self.failingReads = failingReads
        self.failingWrites = failingWrites
    }

    var readCount: Int { lock.withLock { reads } }
    var writeCount: Int { lock.withLock { writes } }
    var storedToken: GoogleOAuthToken? { lock.withLock { token } }

    func makeStore() -> CachedGoogleTokenStore {
        CachedGoogleTokenStore(load: { try self.load() }, save: { try self.save($0) })
    }

    private func load() throws -> GoogleOAuthToken? {
        try lock.withLock {
            reads += 1
            if failingReads.contains(reads) { throw Failure.read }
            return token
        }
    }

    private func save(_ token: GoogleOAuthToken) throws {
        try lock.withLock {
            writes += 1
            if failingWrites.contains(writes) { throw Failure.write }
            self.token = token
        }
    }
}

private final class CachedGoogleRefreshURLProtocol: URLProtocol, @unchecked Sendable {
    // Intercept every request, including unexpected ones, so this fixture cannot fall through to the network.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            let body: [String: Any]
            switch (url.host, url.path, request.httpMethod) {
            case ("oauth2.googleapis.com", "/token", "POST"):
                // A distinct access token reveals any unexpected extra refresh; omission preserves R.
                body = ["access_token": "synthetic-\(UUID().uuidString)", "expires_in": 3600]
            case ("www.googleapis.com", "/calendar/v3/calendars/primary/events", "GET"):
                guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
                      authorization.hasPrefix("Bearer synthetic-") else {
                    throw URLError(.userAuthenticationRequired)
                }
                body = ["items": [[
                    "id": String(authorization.dropFirst("Bearer ".count)),
                    "summary": "Synthetic meeting",
                    "start": ["dateTime": "2026-10-25T10:00:00Z"],
                    "end": ["dateTime": "2026-10-25T11:00:00Z"]
                ]]]
            default:
                throw URLError(.unsupportedURL)
            }
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                        headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
