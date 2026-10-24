import Foundation
import FoundationXML
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct EWSRequestBuilder {
    public static func makeRequest(settings: ExchangeSettings, password: String, from start: Date, to end: Date) throws -> URLRequest {
        var request = URLRequest(url: try settings.endpointURL())
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("http://schemas.microsoft.com/exchange/services/2006/messages/FindItem", forHTTPHeaderField: "SOAPAction")
        if let authorization = settings.authorizationHeader(password: password) {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        let formatter = ISO8601DateFormatter()
        let startString = formatter.string(from: start)
        let endString = formatter.string(from: end)
        request.httpBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
          <soap:Body><m:FindItem Traversal="Shallow"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties><t:FieldURI FieldURI="item:Subject"/><t:FieldURI FieldURI="calendar:Start"/><t:FieldURI FieldURI="calendar:End"/><t:FieldURI FieldURI="calendar:Location"/><t:FieldURI FieldURI="item:Body"/></t:AdditionalProperties></m:ItemShape><m:CalendarView StartDate="\(startString)" EndDate="\(endString)" MaxEntriesReturned="1000"/><m:ParentFolderIds><t:DistinguishedFolderId Id="calendar"/></m:ParentFolderIds></m:FindItem></soap:Body>
        </soap:Envelope>
        """.data(using: .utf8)
        return request
    }
}

public struct EWSCalendarProvider: MeetingCalendarProvider, Sendable {
    public let name = "Exchange (EWS)"
    private let settings: ExchangeSettings
    private let password: String
    private let session: URLSession

    public init(settings: ExchangeSettings, password: String, session: URLSession = .shared) {
        self.settings = settings
        self.password = password
        self.session = session
    }

    public func fetchMeetings(from start: Date, to end: Date) async throws -> [Meeting] {
        let request = try EWSRequestBuilder.makeRequest(settings: settings, password: password, from: start, to: end)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CalendarProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw CalendarProviderError.httpStatus(http.statusCode) }
        return try EWSCalendarParser.parse(data)
    }
}

public enum EWSCalendarParser {
    public static func parse(_ data: Data) throws -> [Meeting] {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? CalendarProviderError.invalidResponse }
        return delegate.meetings
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var meetings: [Meeting] = []
        private var inCalendarItem = false
        private var field: String?
        private var values: [String: String] = [:]
        private var itemID: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let name = String(elementName.split(separator: ":").last ?? Substring(elementName))
            if name == "CalendarItem" {
                inCalendarItem = true
                values = [:]
                itemID = nil
            } else if inCalendarItem && name == "ItemId" {
                itemID = attributeDict["Id"]
            } else if inCalendarItem && ["Subject", "Start", "End", "Location", "Body"].contains(name) {
                field = name
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inCalendarItem, let field else { return }
            values[field, default: ""] += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = String(elementName.split(separator: ":").last ?? Substring(elementName))
            if name == field { field = nil }
            guard name == "CalendarItem", inCalendarItem else { return }
            inCalendarItem = false
            guard let start = Self.parseDate(values["Start"]), let end = Self.parseDate(values["End"]) else { return }
            let id = itemID ?? "ews:\(start.timeIntervalSince1970):\(values["Subject"] ?? "meeting")"
            let description = [values["Location"], values["Body"]].compactMap { $0 }.joined(separator: "\n")
            meetings.append(Meeting(id: "ews:\(id)", title: values["Subject"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Untitled meeting", start: start, end: end, conferenceURL: ConferenceURLRecognizer.firstURL(in: description)))
        }

        private static func parseDate(_ value: String?) -> Date? {
            guard let value else { return nil }
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: value)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
