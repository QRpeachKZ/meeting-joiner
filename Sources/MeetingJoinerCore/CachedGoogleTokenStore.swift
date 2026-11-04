import Foundation

public final class CachedGoogleTokenStore: GoogleTokenStoring, @unchecked Sendable {
    private enum State {
        case unloaded
        case loaded(GoogleOAuthToken?)
    }

    private let lock = NSLock()
    private let persistenceLoad: @Sendable () throws -> GoogleOAuthToken?
    private let persistenceSave: @Sendable (GoogleOAuthToken) throws -> Void
    private var state: State = .unloaded

    public init(load: @escaping @Sendable () throws -> GoogleOAuthToken?,
                save: @escaping @Sendable (GoogleOAuthToken) throws -> Void) {
        persistenceLoad = load
        persistenceSave = save
    }

    public func loadToken() throws -> GoogleOAuthToken? {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    public func saveToken(_ token: GoogleOAuthToken) throws {
        lock.lock()
        defer { lock.unlock() }
        try persistenceSave(token)
        state = .loaded(token)
    }

    public func replaceToken(_ token: GoogleOAuthToken, ifCurrent current: GoogleOAuthToken) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard try loadLocked() == current else { return false }
        if let refreshToken = current.refreshToken, !refreshToken.isEmpty,
           token.refreshToken == refreshToken {
            // The durable refresh credential is unchanged; keep only the new access snapshot in memory.
            state = .loaded(token)
            return true
        }
        try persistenceSave(token)
        state = .loaded(token)
        return true
    }

    private func loadLocked() throws -> GoogleOAuthToken? {
        switch state {
        case .unloaded:
            let token = try persistenceLoad()
            state = .loaded(token)
            return token
        case .loaded(let token):
            return token
        }
    }
}
