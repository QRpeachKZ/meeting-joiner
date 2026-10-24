import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GoogleOAuthToken: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public protocol GoogleTokenStoring: Sendable {
    func loadToken() throws -> GoogleOAuthToken?
    func saveToken(_ token: GoogleOAuthToken) throws
}

public struct GoogleOAuthService: Sendable {
    private let clientID: String
    private let clientSecret: String?
    private let session: URLSession

    public init(clientID: String, clientSecret: String? = nil, session: URLSession = .shared) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.session = session
    }

    public func exchangeAuthorizationCode(_ code: String, verifier: String, redirectURI: String) async throws -> GoogleOAuthToken {
        var fields = ["client_id": clientID, "code": code, "code_verifier": verifier,
                      "grant_type": "authorization_code", "redirect_uri": redirectURI]
        if let clientSecret, !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
        return try await tokenRequest(fields)
    }

    public func refresh(_ token: GoogleOAuthToken) async throws -> GoogleOAuthToken {
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw CalendarProviderError.missingRefreshToken
        }
        var fields = ["client_id": clientID, "refresh_token": refreshToken, "grant_type": "refresh_token"]
        if let clientSecret, !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
        var refreshed = try await tokenRequest(fields)
        if refreshed.refreshToken == nil { refreshed.refreshToken = refreshToken }
        return refreshed
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> GoogleOAuthToken {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(fields).data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CalendarProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw CalendarProviderError.api("Google OAuth failed with HTTP \(http.statusCode).")
        }
        let responseBody = try JSONDecoder().decode(TokenResponse.self, from: data)
        return GoogleOAuthToken(accessToken: responseBody.accessToken,
                                refreshToken: responseBody.refreshToken,
                                expiresAt: Date().addingTimeInterval(responseBody.expiresIn))
    }

    fileprivate static func formEncoded(_ values: [String: String]) -> String {
        values.keys.sorted().map { key in
            "\(formEscape(key))=\(formEscape(values[key] ?? ""))"
        }.joined(separator: "&")
    }

    private static func formEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._*"))?.replacingOccurrences(of: "%20", with: "+") ?? value
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
        }
    }
}

public struct GoogleCalendarProvider: MeetingCalendarProvider, Sendable {
    public let name = "Google Calendar"
    private let clientID: String
    private let clientSecret: String?
    private let calendarID: String
    private let tokenStore: any GoogleTokenStoring
    private let session: URLSession

    public init(clientID: String, clientSecret: String? = nil, calendarID: String = "primary",
                tokenStore: any GoogleTokenStoring, session: URLSession = .shared) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.calendarID = calendarID
        self.tokenStore = tokenStore
        self.session = session
    }

    public func fetchMeetings(from start: Date, to end: Date) async throws -> [Meeting] {
        guard var token = try tokenStore.loadToken() else { throw CalendarProviderError.missingRefreshToken }
        if token.expiresAt <= Date().addingTimeInterval(60) {
            token = try await GoogleOAuthService(clientID: clientID, clientSecret: clientSecret, session: session).refresh(token)
            try tokenStore.saveToken(token)
        }
        let pathCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~@")
        let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: pathCharacters) ?? calendarID
        var allEvents: [GoogleEvent] = []
        var nextPageToken: String?
        var seenPageTokens = Set<String>()
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events")!
            components.queryItems = [URLQueryItem(name: "timeMin", value: ISO8601DateFormatter().string(from: start)),
                                     URLQueryItem(name: "timeMax", value: ISO8601DateFormatter().string(from: end)),
                                     URLQueryItem(name: "singleEvents", value: "true"),
                                     URLQueryItem(name: "orderBy", value: "startTime")]
            if let nextPageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: nextPageToken)) }
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CalendarProviderError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw CalendarProviderError.httpStatus(http.statusCode) }
            let page = try JSONDecoder().decode(EventsResponse.self, from: data)
            allEvents.append(contentsOf: page.items)
            nextPageToken = page.nextPageToken
            if let nextPageToken, !seenPageTokens.insert(nextPageToken).inserted {
                throw CalendarProviderError.invalidResponse
            }
        } while nextPageToken != nil
        return allEvents.compactMap { event in
            guard let startDate = event.start.dateValue, let endDate = event.end.dateValue, let id = event.id else { return nil }
            let link = event.hangoutLink.flatMap(ConferenceURLRecognizer.firstURL(in:))
                ?? ConferenceURLRecognizer.firstURL(in: [event.location, event.description].compactMap { $0 }.joined(separator: "\n"))
            return Meeting(id: "google:\(id)", title: event.summary ?? "Untitled meeting", start: startDate, end: endDate, conferenceURL: link)
        }
    }

    private struct EventsResponse: Decodable {
        let items: [GoogleEvent]
        let nextPageToken: String?
    }
    private struct GoogleEvent: Decodable {
        let id: String?
        let summary: String?
        let description: String?
        let location: String?
        let hangoutLink: String?
        let start: GoogleDate
        let end: GoogleDate
    }
    private struct GoogleDate: Decodable {
        let dateTime: String?
        let date: String?
        var dateValue: Date? {
            if let dateTime {
                let formatter = ISO8601DateFormatter()
                return formatter.date(from: dateTime) ?? {
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return formatter.date(from: dateTime)
                }()
            }
            guard let date else { return nil }
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .iso8601)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: date)
        }
    }
}
