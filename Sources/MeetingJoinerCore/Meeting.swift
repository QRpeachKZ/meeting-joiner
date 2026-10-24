import Foundation

public struct Meeting: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var conferenceURL: URL?

    public init(id: String, title: String, start: Date, end: Date, conferenceURL: URL? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.conferenceURL = conferenceURL
    }
}

public protocol MeetingCalendarProvider: Sendable {
    var name: String { get }
    func fetchMeetings(from start: Date, to end: Date) async throws -> [Meeting]
}

public enum CalendarProviderError: Error, LocalizedError {
    case httpStatus(Int)
    case invalidResponse
    case missingRefreshToken
    case api(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let status): return "Calendar service returned HTTP \(status)."
        case .invalidResponse: return "Calendar service returned an invalid response."
        case .missingRefreshToken: return "Google authorization has no refresh token; reconnect the account."
        case .api(let message): return message
        }
    }
}
