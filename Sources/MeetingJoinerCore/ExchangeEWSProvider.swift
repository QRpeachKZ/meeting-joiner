import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct EWSRequestBuilder {
    public static func makeRequest(settings: ExchangeSettings, password: String, from start: Date, to end: Date) throws -> URLRequest {
        let formatter = ISO8601DateFormatter()
        let body = """
        <m:FindItem Traversal="Shallow"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>\(calendarProperties)</t:AdditionalProperties></m:ItemShape><m:CalendarView StartDate="\(formatter.string(from: start))" EndDate="\(formatter.string(from: end))" MaxEntriesReturned="1000"/><m:ParentFolderIds><t:DistinguishedFolderId Id="calendar"/></m:ParentFolderIds></m:FindItem>
        """
        return try request(settings: settings, password: password, operation: "FindItem", body: body)
    }

    fileprivate static func makeGetItemRequest(settings: ExchangeSettings, password: String, itemIDs: [String]) throws -> URLRequest {
        let ids = itemIDs.map { "<t:ItemId Id=\"\(escapeAttribute($0))\"/>" }.joined()
        let body = """
        <m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>\(calendarProperties)<t:FieldURI FieldURI="item:Body"/></t:AdditionalProperties></m:ItemShape><m:ItemIds>\(ids)</m:ItemIds></m:GetItem>
        """
        return try request(settings: settings, password: password, operation: "GetItem", body: body)
    }

    private static let calendarProperties = """
    <t:FieldURI FieldURI="item:Subject"/><t:FieldURI FieldURI="calendar:Start"/><t:FieldURI FieldURI="calendar:End"/><t:FieldURI FieldURI="calendar:Location"/>
    """

    private static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\t", with: "&#9;")
            .replacingOccurrences(of: "\n", with: "&#10;")
            .replacingOccurrences(of: "\r", with: "&#13;")
    }

    private static func request(settings: ExchangeSettings, password: String, operation: String, body: String) throws -> URLRequest {
        var request = URLRequest(url: try settings.endpointURL())
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("http://schemas.microsoft.com/exchange/services/2006/messages/\(operation)", forHTTPHeaderField: "SOAPAction")
        if let authorization = settings.authorizationHeader(password: password) {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
          <soap:Body>\(body)</soap:Body>
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
    private static let getItemBatchSize = 100

    public init(settings: ExchangeSettings, password: String, session: URLSession = .shared) {
        self.settings = settings
        self.password = password
        self.session = session
    }

    public func fetchMeetings(from start: Date, to end: Date) async throws -> [Meeting] {
        try Task.checkCancellation()
        let request = try EWSRequestBuilder.makeRequest(settings: settings, password: password, from: start, to: end)
        let ids = try EWSCalendarParser.findItemIDs(await send(request))
        var meetings: [Meeting] = []
        for offset in stride(from: 0, to: ids.count, by: Self.getItemBatchSize) {
            try Task.checkCancellation()
            let batch = Array(ids[offset..<min(offset + Self.getItemBatchSize, ids.count)])
            let request = try EWSRequestBuilder.makeGetItemRequest(settings: settings, password: password, itemIDs: batch)
            let items = try EWSCalendarParser.parse(await send(request))
            guard items.count == batch.count, Set(items.map(\.id)) == Set(batch.map { "ews:\($0)" }) else {
                throw CalendarProviderError.invalidResponse
            }
            meetings.append(contentsOf: items)
        }
        try Task.checkCancellation()
        return meetings
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CalendarProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw CalendarProviderError.httpStatus(http.statusCode) }
        return data
    }
}

public enum EWSCalendarParser {
    private static let soap = "http://schemas.xmlsoap.org/soap/envelope/"
    private static let messages = "http://schemas.microsoft.com/exchange/services/2006/messages"
    private static let types = "http://schemas.microsoft.com/exchange/services/2006/types"

    public static func parse(_ data: Data) throws -> [Meeting] {
        try responseMessages(data, operation: "GetItem").flatMap { message in
            let items = try message.requiredChild("Items", namespace: messages)
            return try calendarItems(items).map { item in
                let id = try itemID(item)
                guard let start = parseDate(try item.value("Start", namespace: types)),
                      let end = parseDate(try item.value("End", namespace: types)), end >= start else {
                    throw CalendarProviderError.invalidResponse
                }
                let title = try item.value("Subject", namespace: types)?.trimmingCharacters(in: .whitespacesAndNewlines)
                var body = try item.value("Body", namespace: types)
                if let text = body, item.children.first(where: { $0.matches("Body", namespace: types) })?.attributes["BodyType"] == "HTML" {
                    body = decodeHTMLEntities(text)
                }
                let description = try [item.value("Location", namespace: types), body]
                    .compactMap { $0 }.joined(separator: "\n")
                return Meeting(id: "ews:\(id)", title: title?.nonEmpty ?? "Untitled meeting", start: start, end: end,
                               conferenceURL: ConferenceURLRecognizer.firstURL(in: description))
            }
        }
    }

    fileprivate static func findItemIDs(_ data: Data) throws -> [String] {
        let ids = try responseMessages(data, operation: "FindItem").flatMap { message -> [String] in
            let root = try message.requiredChild("RootFolder", namespace: messages)
            switch root.attributes["IncludesLastItemInRange"] {
            case "true", "1": break
            case "false", "0": throw CalendarProviderError.api("Exchange returned an incomplete calendar range; narrow the sync range or enable paging.")
            default: throw CalendarProviderError.invalidResponse
            }
            return try calendarItems(root.requiredChild("Items", namespace: types)).map { try itemID($0) }
        }
        guard Set(ids).count == ids.count else { throw CalendarProviderError.invalidResponse }
        return ids
    }

    private static func responseMessages(_ data: Data, operation: String) throws -> [Element] {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let envelope = delegate.root, envelope.matches("Envelope", namespace: soap) else {
            throw CalendarProviderError.invalidResponse
        }
        let body = try envelope.requiredChild("Body", namespace: soap)
        if body.children.contains(where: { $0.matches("Fault", namespace: soap) }) {
            throw CalendarProviderError.api("Exchange returned a SOAP fault.")
        }
        guard body.children.count == 1, body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let response = body.children.first, response.matches("\(operation)Response", namespace: messages),
              response.children.count == 1 else {
            throw CalendarProviderError.invalidResponse
        }
        let container = try response.requiredChild("ResponseMessages", namespace: messages)
        guard !container.children.isEmpty, container.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CalendarProviderError.invalidResponse
        }
        for message in container.children {
            guard message.matches("\(operation)ResponseMessage", namespace: messages),
                  let responseClass = message.attributes["ResponseClass"],
                  ["Success", "Warning", "Error"].contains(responseClass),
                  let code = try message.value("ResponseCode", namespace: messages)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !code.isEmpty else { throw CalendarProviderError.invalidResponse }
            guard responseClass == "Success", code == "NoError" else {
                throw CalendarProviderError.api("Exchange \(operation) failed: \(code).")
            }
        }
        return container.children
    }

    private static func calendarItems(_ container: Element) throws -> [Element] {
        guard container.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              container.children.allSatisfy({ $0.matches("CalendarItem", namespace: types) }) else {
            throw CalendarProviderError.invalidResponse
        }
        return container.children
    }

    private static func itemID(_ item: Element) throws -> String {
        let element = try item.requiredChild("ItemId", namespace: types)
        guard let id = element.attributes["Id"], !id.isEmpty else { throw CalendarProviderError.invalidResponse }
        return id
    }

    private static let htmlEntityExpression = try? NSRegularExpression(
        pattern: "&(#(?:[0-9]+|[xX][0-9a-fA-F]+)|amp|AMP|lt|LT|gt|GT|quot|QUOT|apos|nbsp);"
    )

    private static func decodeHTMLEntities(_ text: String) -> String {
        guard let expression = htmlEntityExpression else { return text }
        var decoded = ""
        var cursor = text.startIndex
        // Decode the HTML layer once; XMLParser already removed the SOAP XML layer.
        for match in expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
            guard let range = Range(match.range, in: text), let entityRange = Range(match.range(at: 1), in: text) else { continue }
            let entity = text[entityRange]
            let replacement: String
            switch entity {
            case "amp", "AMP": replacement = "&"
            case "lt", "LT": replacement = "<"
            case "gt", "GT": replacement = ">"
            case "quot", "QUOT": replacement = "\""
            case "apos": replacement = "'"
            case "nbsp": replacement = "\u{00A0}"
            default:
                let isHex = entity.hasPrefix("#x") || entity.hasPrefix("#X")
                if let value = UInt32(entity.dropFirst(isHex ? 2 : 1), radix: isHex ? 16 : 10),
                   value != 0, let scalar = UnicodeScalar(value) {
                    replacement = String(scalar)
                } else {
                    // Preserve invalid or overflowing references rather than inventing URL text.
                    replacement = String(text[range])
                }
            }
            decoded.append(contentsOf: text[cursor..<range.lowerBound])
            decoded.append(contentsOf: replacement)
            cursor = range.upperBound
        }
        decoded.append(contentsOf: text[cursor...])
        return decoded
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    private final class Element {
        let name: String
        let namespace: String?
        let attributes: [String: String]
        var children: [Element] = []
        var text = ""

        init(name: String, namespace: String?, attributes: [String: String]) {
            self.name = name
            self.namespace = namespace
            self.attributes = attributes
        }

        func matches(_ name: String, namespace: String) -> Bool {
            self.name == name && self.namespace == namespace
        }

        func requiredChild(_ name: String, namespace: String) throws -> Element {
            let matching = children.filter { $0.matches(name, namespace: namespace) }
            guard matching.count == 1, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CalendarProviderError.invalidResponse
            }
            return matching[0]
        }

        func value(_ name: String, namespace: String) throws -> String? {
            let matching = children.filter { $0.matches(name, namespace: namespace) }
            guard matching.count <= 1, matching.first?.children.isEmpty != false else { throw CalendarProviderError.invalidResponse }
            return matching.first?.text
        }
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var root: Element?
        private var stack: [Element] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let element = Element(name: elementName, namespace: namespaceURI, attributes: attributeDict)
            if let parent = stack.last {
                parent.children.append(element)
            } else {
                root = element
            }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let text = String(data: CDATABlock, encoding: .utf8) else {
                parser.abortParsing()
                return
            }
            stack.last?.text += text
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
