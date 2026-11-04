import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MeetingJoinerCore

final class ExchangeRegressionTests: XCTestCase {
    func testFindItemThenGetItemUsesBodyAndUpdatedCalendarFields() async throws {
        let fixture = ExchangeFixture(replies: [
            .xml(ExchangeXML.find([ExchangeXML.findMessage(ids: ["item-1"])])),
            .xml(ExchangeXML.get([ExchangeXML.getMessage(items: ExchangeXML.item(id: "item-1", title: "Updated planning", body: "<![CDATA[<a href=\"https://meet.google.com/abc-defg-hij\">Join</a>]]>"))]))
        ])
        let meetings = try await fixture.fetch()
        XCTAssertEqual(meetings.count, 1)
        XCTAssertEqual(meetings.first?.id, "ews:item-1")
        XCTAssertEqual(meetings.first?.title, "Updated planning")
        XCTAssertEqual(meetings.first?.conferenceURL?.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(fixture.requests.count, 2)
        let find = try XCTUnwrap(fixture.requests.first)
        let get = try XCTUnwrap(fixture.requests.last)
        XCTAssertTrue(find.value(forHTTPHeaderField: "SOAPAction")?.hasSuffix("/FindItem") == true)
        XCTAssertFalse(ExchangeMockProtocol.body(find).contains("item:Body"))
        XCTAssertTrue(get.value(forHTTPHeaderField: "SOAPAction")?.hasSuffix("/GetItem") == true)
        for field in ["item:Body", "item:Subject", "calendar:Start", "calendar:End", "calendar:Location"] {
            XCTAssertTrue(ExchangeMockProtocol.body(get).contains("FieldURI=\"\(field)\""))
        }
        for request in fixture.requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testHTMLBodyInCDATAUnescapesQuerySeparators() async throws {
        let body = "<![CDATA[<a href=\"https://zoom.us/j/123?uname=x&amp;pwd=test-code&amp;lang=ru\">Join</a>]]>"
        let queryItems = try await bodyQueryItems(body)
        XCTAssertEqual(queryItems, [
            URLQueryItem(name: "uname", value: "x"),
            URLQueryItem(name: "pwd", value: "test-code"),
            URLQueryItem(name: "lang", value: "ru")
        ])
    }

    func testHTMLBodyInXMLTextUnescapesQuerySeparators() async throws {
        let body = "&lt;a href=&quot;https://zoom.us/j/123?uname=x&amp;amp;pwd=test-code&amp;amp;lang=ru&quot;&gt;Join&lt;/a&gt;"
        let queryItems = try await bodyQueryItems(body)
        XCTAssertEqual(queryItems, [
            URLQueryItem(name: "uname", value: "x"),
            URLQueryItem(name: "pwd", value: "test-code"),
            URLQueryItem(name: "lang", value: "ru")
        ])
    }

    func testHTMLBodyDecodesDecimalAndHexEntitiesInBothSOAPForms() async throws {
        let query = "uname=&#120;&#38;pwd=test&#x2D;code&#X26;lang=&#114;&#117;"
        let bodies = [
            "<![CDATA[<a href=\"https://zoom.us/j/123?\(query)\">Join</a>]]>",
            "&lt;a href=&quot;https://zoom.us/j/123?\(query.replacingOccurrences(of: "&", with: "&amp;"))&quot;&gt;Join&lt;/a&gt;"
        ]
        for body in bodies {
            let queryItems = try await bodyQueryItems(body)
            XCTAssertEqual(queryItems, [
                URLQueryItem(name: "uname", value: "x"),
                URLQueryItem(name: "pwd", value: "test-code"),
                URLQueryItem(name: "lang", value: "ru")
            ])
        }
    }

    func testHTMLBodyDecodesExactlyOneEntityLayer() async throws {
        for separator in ["&amp;amp;", "&#38;amp;", "&#x26;amp;"] {
            let query = "uname=x&amp;pwd=test-code\(separator)literal=keep"
            let bodies = [
                "<![CDATA[<a href=\"https://zoom.us/j/123?\(query)\">Join</a>]]>",
                "&lt;a href=&quot;https://zoom.us/j/123?\(query.replacingOccurrences(of: "&", with: "&amp;"))&quot;&gt;Join&lt;/a&gt;"
            ]
            for body in bodies {
                let queryItems = try await bodyQueryItems(body)
                XCTAssertEqual(queryItems, [
                    URLQueryItem(name: "uname", value: "x"),
                    URLQueryItem(name: "pwd", value: "test-code"),
                    URLQueryItem(name: "amp;literal", value: "keep")
                ])
            }
        }
    }

    func testPlainTextBodyPreservesLiteralHTMLEntitiesInBothSOAPForms() async throws {
        for body in [
            "<![CDATA[https://zoom.us/j/123?uname=x&amp;pwd=test-code&amp;lang=ru]]>",
            "https://zoom.us/j/123?uname=x&amp;amp;pwd=test-code&amp;amp;lang=ru"
        ] {
            let queryItems = try await bodyQueryItems(body, bodyType: "Text")
            XCTAssertEqual(queryItems, [
                URLQueryItem(name: "uname", value: "x"),
                URLQueryItem(name: "amp;pwd", value: "test-code"),
                URLQueryItem(name: "amp;lang", value: "ru")
            ])
        }
    }

    func testHTMLBodyStillRejectsUnsafeSchemesAndHosts() async throws {
        for candidate in [
            "http&#58;//zoom.us/j/123", "javascript&#58;alert(1)", "file&#58;///tmp/meeting",
            "https&#58;//zoom.us.evil.example/j/123", "https&#58;//evilzoom.us/j/123"
        ] {
            let fixture = ExchangeFixture(replies: [
                .xml(ExchangeXML.find([ExchangeXML.findMessage(ids: ["item-1"])])),
                .xml(ExchangeXML.get([ExchangeXML.getMessage(items: ExchangeXML.item(id: "item-1", body: "<![CDATA[<a href=\"\(candidate)\">Join</a>]]>"))]))
            ])
            let meetings = try await fixture.fetch()
            XCTAssertEqual(meetings.count, 1)
            XCTAssertNil(meetings.first?.conferenceURL, candidate)
        }
    }

    func testCancelledBeforeFetchThrowsCancellationWithoutRequests() async {
        let fixture = ExchangeFixture(replies: [])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.fetch()
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation before fetching")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testGetItemEscapesOpaqueIDsWithoutChangingThem() async throws {
        let id = "opaque<&>\"'\t\n\r/+=not-base64"
        let fixture = ExchangeFixture(replies: [
            .xml(ExchangeXML.find([ExchangeXML.findMessage(ids: [id])])),
            .xml(ExchangeXML.get([ExchangeXML.getMessage(items: ExchangeXML.item(id: id))]))
        ])
        let meetings = try await fixture.fetch()
        XCTAssertEqual(meetings.first?.id, "ews:\(id)")
        let request = try XCTUnwrap(fixture.requests.last)
        XCTAssertTrue(ExchangeMockProtocol.body(request).contains("<t:ItemId Id=\"opaque&lt;&amp;&gt;&quot;&apos;&#9;&#10;&#13;/+=not-base64\"/>"))
    }

    func testGetItemUsesBoundedBatches() async throws {
        let ids = (0..<201).map { "item-\($0)" }
        var replies: [ExchangeReply] = [.xml(ExchangeXML.find([ExchangeXML.findMessage(ids: ids)]))]
        for offset in stride(from: 0, to: ids.count, by: 100) {
            let batch = ids[offset..<min(offset + 100, ids.count)]
            replies.append(.xml(ExchangeXML.get(batch.map { ExchangeXML.getMessage(items: ExchangeXML.item(id: $0)) })))
        }
        let fixture = ExchangeFixture(replies: replies)
        let meetings = try await fixture.fetch()
        XCTAssertEqual(meetings.count, ids.count)
        XCTAssertEqual(fixture.requests.count, 4)
        XCTAssertEqual(fixture.requests.dropFirst().map { ExchangeMockProtocol.body($0).components(separatedBy: "<t:ItemId Id=").count - 1 }, [100, 100, 1])
    }

    func testLaterBatchFailureDoesNotReturnEarlierMeetings() async {
        let ids = (0..<101).map { "item-\($0)" }
        let fixture = ExchangeFixture(replies: [
            .xml(ExchangeXML.find([ExchangeXML.findMessage(ids: ids)])),
            .xml(ExchangeXML.get(ids.prefix(100).map { ExchangeXML.getMessage(items: ExchangeXML.item(id: $0)) })),
            .xml(ExchangeXML.get([ExchangeXML.message(operation: "GetItem", responseClass: "Error", code: "ErrorAccessDenied")]))
        ])
        await assertFailure(fixture)
        XCTAssertEqual(fixture.requests.count, 3)
    }

    func testEmptyFindMessagesAreSuccessfulWithoutGetItem() async throws {
        let fixture = ExchangeFixture(replies: [.xml(ExchangeXML.find([
            ExchangeXML.findMessage(ids: []), ExchangeXML.findMessage(ids: [])
        ]))])
        let meetings = try await fixture.fetch()
        XCTAssertTrue(meetings.isEmpty)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testMultipleFindMessagesIncludeItemsAfterEmptyMessage() async throws {
        let fixture = ExchangeFixture(replies: [
            .xml(ExchangeXML.find([ExchangeXML.findMessage(ids: []), ExchangeXML.findMessage(ids: ["second"])])),
            .xml(ExchangeXML.get([ExchangeXML.getMessage(items: ExchangeXML.item(id: "second"))]))
        ])
        let meetings = try await fixture.fetch()
        XCTAssertEqual(meetings.map(\.id), ["ews:second"])
    }

    func testMultipleGetMessagesAndEmptySuccess() throws {
        let xml = ExchangeXML.get([
            ExchangeXML.getMessage(items: ""),
            ExchangeXML.getMessage(items: ExchangeXML.item(id: "first")),
            ExchangeXML.getMessage(items: ExchangeXML.item(id: "second", body: "&lt;a href=&quot;https://zoom.us/j/123&quot;&gt;Join&lt;/a&gt;"))
        ])
        let meetings = try EWSCalendarParser.parse(Data(xml.utf8))
        XCTAssertEqual(meetings.map(\.id), ["ews:first", "ews:second"])
        XCTAssertEqual(meetings.last?.conferenceURL?.absoluteString, "https://zoom.us/j/123")
        XCTAssertTrue(try EWSCalendarParser.parse(Data(ExchangeXML.get([ExchangeXML.getMessage(items: "")]).utf8)).isEmpty)
    }

    func testAnyErrorOrWarningMessageRejectsEntireGetResponse() {
        for (responseClass, code) in [("Error", "ErrorAccessDenied"), ("Warning", "ErrorBatchProcessingStopped"), ("Success", "ErrorAccessDenied"), ("Error", "NoError")] {
            let xml = ExchangeXML.get([
                ExchangeXML.getMessage(items: ExchangeXML.item(id: "valid")),
                ExchangeXML.message(operation: "GetItem", responseClass: responseClass, code: code)
            ])
            XCTAssertThrowsError(try EWSCalendarParser.parse(Data(xml.utf8))) { error in
                guard case CalendarProviderError.api(let message) = error else { return XCTFail("Expected EWS error, got \(error)") }
                XCTAssertTrue(message.contains(code))
            }
        }
    }

    func testFindErrorAfterEmptySuccessIsNotEmptyCalendar() async {
        let fixture = ExchangeFixture(replies: [.xml(ExchangeXML.find([
            ExchangeXML.findMessage(ids: []),
            ExchangeXML.message(operation: "FindItem", responseClass: "Error", code: "ErrorAccessDenied")
        ]))])
        await assertFailure(fixture) { error in
            guard case CalendarProviderError.api(let message) = error else { return XCTFail("Expected EWS error") }
            XCTAssertTrue(message.contains("ErrorAccessDenied"))
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testGetErrorAfterSuccessRejectsSnapshot() async {
        let fixture = ExchangeFixture(replies: [
            .xml(ExchangeXML.find([ExchangeXML.findMessage(ids: ["first", "second"])])),
            .xml(ExchangeXML.get([
                ExchangeXML.getMessage(items: ExchangeXML.item(id: "first")),
                ExchangeXML.message(operation: "GetItem", responseClass: "Error", code: "ErrorItemNotFound")
            ]))
        ])
        await assertFailure(fixture)
    }

    func testIncompleteFindRangeIsExplicitFailureBeforeGetItem() async {
        for value in ["false", "0"] {
            let fixture = ExchangeFixture(replies: [.xml(ExchangeXML.find([ExchangeXML.findMessage(ids: ["first"], includesLast: value)]))])
            await assertFailure(fixture) { error in
                guard case CalendarProviderError.api(let message) = error else { return XCTFail("Expected incomplete range error") }
                XCTAssertTrue(message.contains("incomplete"))
            }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testMissingOrInvalidRangeFlagAndDuplicateIDsAreRejected() async {
        let valid = ExchangeXML.find([ExchangeXML.findMessage(ids: [])])
        let responses = [
            valid.replacingOccurrences(of: " IncludesLastItemInRange=\"true\"", with: ""),
            valid.replacingOccurrences(of: "IncludesLastItemInRange=\"true\"", with: "IncludesLastItemInRange=\"unknown\""),
            ExchangeXML.find([ExchangeXML.findMessage(ids: ["duplicate", "duplicate"])])
        ]
        for response in responses {
            let fixture = ExchangeFixture(replies: [.xml(response)])
            await assertFailure(fixture)
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testSOAPFaultsAreRejectedAtBothStages() async {
        let fault = ExchangeXML.envelope("<s:Fault><faultcode>s:Server</faultcode><faultstring>Access denied</faultstring></s:Fault>")
        XCTAssertThrowsError(try EWSCalendarParser.parse(Data(fault.utf8)))
        await assertFailure(ExchangeFixture(replies: [.xml(fault)]))
        await assertFailure(ExchangeFixture(replies: [
            .xml(ExchangeXML.find([ExchangeXML.findMessage(ids: ["first"])])), .xml(fault)
        ]))
    }

    func testHTTPFailuresAreRejectedAtBothStages() async {
        for status in [401, 403, 500] {
            let errorReply = ExchangeReply.xml("not SOAP", status: status)
            let check: (Error) -> Void = { error in
                guard case CalendarProviderError.httpStatus(let received) = error else { return XCTFail("Expected HTTP error") }
                XCTAssertEqual(received, status)
            }
            await assertFailure(ExchangeFixture(replies: [errorReply]), check: check)
            await assertFailure(ExchangeFixture(replies: [
                .xml(ExchangeXML.find([ExchangeXML.findMessage(ids: ["first"])])), errorReply
            ]), check: check)
        }
    }

    func testNonHTTPResponseIsRejected() async {
        await assertFailure(ExchangeFixture(replies: [ExchangeReply(data: Data(), status: nil)]))
    }

    func testMalformedAndUnexpectedResponsesAreRejectedAtBothStages() async {
        let responses = ["", "<broken>", "<html/>", ExchangeXML.envelope(""), ExchangeXML.envelope("<m:UnexpectedResponse/>")]
        for response in responses {
            await assertFailure(ExchangeFixture(replies: [.xml(response)]))
            await assertFailure(ExchangeFixture(replies: [
                .xml(ExchangeXML.find([ExchangeXML.findMessage(ids: ["first"])])), .xml(response)
            ]))
        }
        await assertFailure(ExchangeFixture(replies: [.xml(ExchangeXML.get([ExchangeXML.getMessage(items: "")]))]))
        await assertFailure(ExchangeFixture(replies: [
            .xml(ExchangeXML.find([ExchangeXML.findMessage(ids: ["first"])])),
            .xml(ExchangeXML.find([ExchangeXML.findMessage(ids: ["first"])]))
        ]))
    }

    func testInvalidSOAPStructureAndCalendarFieldsAreRejected() {
        let valid = ExchangeXML.get([ExchangeXML.getMessage(items: ExchangeXML.item(id: "first"))])
        let responses = [
            ExchangeXML.get([]),
            ExchangeXML.get([ExchangeXML.message(operation: "FindItem", responseClass: "Success", code: "NoError")]),
            valid.replacingOccurrences(of: "ResponseClass=\"Success\"", with: ""),
            valid.replacingOccurrences(of: "ResponseClass=\"Success\"", with: "ResponseClass=\"Unknown\""),
            valid.replacingOccurrences(of: "<m:ResponseCode>NoError</m:ResponseCode>", with: ""),
            valid.replacingOccurrences(of: "<m:ResponseCode>NoError</m:ResponseCode>", with: "<m:ResponseCode/>"),
            valid.replacingOccurrences(of: "<m:ResponseCode>NoError</m:ResponseCode>", with: "<m:ResponseCode>NoError</m:ResponseCode><m:ResponseCode>ErrorAccessDenied</m:ResponseCode>"),
            valid.replacingOccurrences(of: "http://schemas.microsoft.com/exchange/services/2006/messages", with: "urn:wrong"),
            valid.replacingOccurrences(of: "http://schemas.xmlsoap.org/soap/envelope/", with: "urn:wrong"),
            valid.replacingOccurrences(of: "<t:ItemId Id=\"first\"/>", with: ""),
            valid.replacingOccurrences(of: "2026-10-25T10:00:00Z", with: "invalid-date"),
            valid.replacingOccurrences(of: "2026-10-25T10:30:00Z", with: "2026-10-24T10:30:00Z"),
            valid.replacingOccurrences(of: "t:CalendarItem", with: "t:Message"),
            valid.replacingOccurrences(of: "m:Items", with: "t:Items"),
            valid.replacingOccurrences(of: "<m:Items>", with: "<m:Items>not an item"),
            valid.replacingOccurrences(of: "</s:Body>", with: "<m:UnexpectedResponse/></s:Body>"),
            ExchangeXML.get([ExchangeXML.message(operation: "GetItem")]),
            ExchangeXML.envelope(ExchangeXML.item(id: "legacy"))
        ]
        for (index, response) in responses.enumerated() {
            XCTAssertThrowsError(try EWSCalendarParser.parse(Data(response.utf8)), "Response \(index) must be rejected")
        }
    }

    func testMissingDuplicateOrUnexpectedGetItemsRejectSnapshot() async {
        for items in ["", ExchangeXML.item(id: "first"), ExchangeXML.item(id: "first") + ExchangeXML.item(id: "first"), ExchangeXML.item(id: "first") + ExchangeXML.item(id: "unexpected")] {
            let fixture = ExchangeFixture(replies: [
                .xml(ExchangeXML.find([ExchangeXML.findMessage(ids: ["first", "second"])])),
                .xml(ExchangeXML.get([ExchangeXML.getMessage(items: items)]))
            ])
            await assertFailure(fixture)
        }
    }

    func testNoTLSSendsNoPasswordInEitherOperation() async throws {
        let fixture = ExchangeFixture(replies: [
            .xml(ExchangeXML.find([ExchangeXML.findMessage(ids: ["first"])])),
            .xml(ExchangeXML.get([ExchangeXML.getMessage(items: ExchangeXML.item(id: "first"))]))
        ], mode: .insecureWarning)
        _ = try await fixture.fetch()
        XCTAssertEqual(fixture.requests.count, 2)
        for request in fixture.requests {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.url?.scheme, "http")
        }
    }

    private func bodyQueryItems(_ body: String, bodyType: String = "HTML") async throws -> [URLQueryItem] {
        let fixture = ExchangeFixture(replies: [
            .xml(ExchangeXML.find([ExchangeXML.findMessage(ids: ["item-1"])])),
            .xml(ExchangeXML.get([ExchangeXML.getMessage(items: ExchangeXML.item(id: "item-1", body: body, bodyType: bodyType))]))
        ])
        let meetings = try await fixture.fetch()
        XCTAssertEqual(meetings.count, 1)
        XCTAssertEqual(fixture.requests.count, 2)
        let url = try XCTUnwrap(meetings.first?.conferenceURL)
        return try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    private func assertFailure(_ fixture: ExchangeFixture, file: StaticString = #filePath, line: UInt = #line, check: (Error) -> Void = { _ in }) async {
        do {
            _ = try await fixture.fetch()
            XCTFail("Expected Exchange fetch to fail", file: file, line: line)
        } catch {
            check(error)
        }
    }
}

final class ExchangeSecurityPolicyTests: XCTestCase {
    func testSecureRedirectsRemainOnOriginalHTTPSOriginIncludingPort() {
        for mode in [ExchangeTLSMode.systemTrust, .customCA] {
            let settings = ExchangeSettings(serverURL: "https://exchange.example.org", port: 8443, tlsMode: mode, customCALabel: "Test CA")
            let origin = URL(string: "https://exchange.example.org:8443/EWS/Exchange.asmx")!
            XCTAssertTrue(settings.allowsRedirect(from: origin, to: URL(string: "https://EXCHANGE.example.org:8443/other")!))
            for target in ["https://other.example.org:8443/", "https://exchange.example.org/", "https://exchange.example.org:443/", "http://exchange.example.org:8443/", "https://user:password@exchange.example.org:8443/"] {
                XCTAssertFalse(settings.allowsRedirect(from: origin, to: URL(string: target)!))
            }
            let foreign = URL(string: "https://other.example.org:8443/")!
            XCTAssertFalse(settings.allowsRedirect(from: foreign, to: foreign))
            XCTAssertFalse(settings.allowsRedirect(from: foreign, to: origin))
        }
    }

    func testRedirectDefaultPortsAndNoTLSOriginRestriction() {
        let secure = ExchangeSettings(serverURL: "https://exchange.example.org")
        XCTAssertTrue(secure.allowsRedirect(from: URL(string: "https://exchange.example.org/")!, to: URL(string: "https://exchange.example.org:443/other")!))
        let insecure = ExchangeSettings(serverURL: "http://exchange.example.org", port: 80, tlsMode: .insecureWarning)
        let origin = URL(string: "http://exchange.example.org/")!
        XCTAssertTrue(insecure.allowsRedirect(from: origin, to: URL(string: "http://EXCHANGE.example.org:80/other")!))
        for target in ["http://other.example.org/", "http://exchange.example.org:8080/", "https://exchange.example.org/", "https://exchange.example.org:80/"] {
            XCTAssertFalse(insecure.allowsRedirect(from: origin, to: URL(string: target)!))
        }
    }

    func testClientIdentityRequiresSecureModeAndOriginalHTTPSHostAndPort() {
        for mode in [ExchangeTLSMode.systemTrust, .customCA] {
            let settings = ExchangeSettings(serverURL: "https://exchange.example.org", port: 8443, tlsMode: mode, customCALabel: "Test CA", clientIdentityLabel: "Test identity")
            XCTAssertTrue(settings.allowsClientIdentity(host: "EXCHANGE.example.org", port: 8443, scheme: "HTTPS"))
            XCTAssertFalse(settings.allowsClientIdentity(host: "other.example.org", port: 8443, scheme: "https"))
            XCTAssertFalse(settings.allowsClientIdentity(host: "exchange.example.org", port: 443, scheme: "https"))
            XCTAssertFalse(settings.allowsClientIdentity(host: "exchange.example.org", port: 0, scheme: "https"))
            XCTAssertFalse(settings.allowsClientIdentity(host: "exchange.example.org", port: 8443, scheme: "http"))
            XCTAssertFalse(settings.allowsClientIdentity(host: "exchange.example.org", port: 8443, scheme: nil))
        }
        let insecure = ExchangeSettings(serverURL: "http://exchange.example.org", port: 443, tlsMode: .insecureWarning, clientIdentityLabel: "Test identity")
        XCTAssertFalse(insecure.allowsClientIdentity(host: "exchange.example.org", port: 443, scheme: "https"))
        XCTAssertFalse(insecure.allowsClientIdentity(host: "exchange.example.org", port: 443, scheme: "http"))
        let standard = ExchangeSettings(serverURL: "https://exchange.example.org")
        XCTAssertTrue(standard.allowsClientIdentity(host: "exchange.example.org", port: 443, scheme: "https"))
    }

    func testInvalidSettingsFailClosed() {
        for settings in [ExchangeSettings(serverURL: "http://exchange.example.org"), ExchangeSettings(tlsMode: .customCA), ExchangeSettings(port: 0)] {
            let url = URL(string: "https://exchange.example.org/")!
            XCTAssertFalse(settings.allowsRedirect(from: url, to: url))
            XCTAssertFalse(settings.allowsClientIdentity(host: "exchange.example.org", port: 443, scheme: "https"))
        }
    }
}

private enum ExchangeXML {
    static func envelope(_ body: String) -> String {
        "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:m=\"http://schemas.microsoft.com/exchange/services/2006/messages\" xmlns:t=\"http://schemas.microsoft.com/exchange/services/2006/types\"><s:Body>\(body)</s:Body></s:Envelope>"
    }

    static func find(_ messages: [String]) -> String {
        envelope("<m:FindItemResponse><m:ResponseMessages>\(messages.joined())</m:ResponseMessages></m:FindItemResponse>")
    }

    static func get(_ messages: [String]) -> String {
        envelope("<m:GetItemResponse><m:ResponseMessages>\(messages.joined())</m:ResponseMessages></m:GetItemResponse>")
    }

    static func message(operation: String, responseClass: String = "Success", code: String = "NoError", content: String = "") -> String {
        "<m:\(operation)ResponseMessage ResponseClass=\"\(responseClass)\"><m:ResponseCode>\(code)</m:ResponseCode>\(content)</m:\(operation)ResponseMessage>"
    }

    static func findMessage(ids: [String], includesLast: String = "true") -> String {
        let items = ids.map { "<t:CalendarItem><t:ItemId Id=\"\(escape($0))\"/><t:Subject>Find title</t:Subject><t:Start>2026-10-25T09:00:00Z</t:Start><t:End>2026-10-25T09:30:00Z</t:End></t:CalendarItem>" }.joined()
        return message(operation: "FindItem", content: "<m:RootFolder TotalItemsInView=\"\(ids.count)\" IncludesLastItemInRange=\"\(includesLast)\"><t:Items>\(items)</t:Items></m:RootFolder>")
    }

    static func getMessage(items: String) -> String {
        message(operation: "GetItem", content: "<m:Items>\(items)</m:Items>")
    }

    static func item(id: String, title: String = "Planning", body: String = "", bodyType: String = "HTML") -> String {
        "<t:CalendarItem><t:ItemId Id=\"\(escape(id))\"/><t:Subject>\(escape(title))</t:Subject><t:Start>2026-10-25T10:00:00Z</t:Start><t:End>2026-10-25T10:30:00Z</t:End><t:Body BodyType=\"\(escape(bodyType))\">\(body)</t:Body></t:CalendarItem>"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\t", with: "&#9;")
            .replacingOccurrences(of: "\n", with: "&#10;")
            .replacingOccurrences(of: "\r", with: "&#13;")
    }
}

private struct ExchangeReply {
    let data: Data
    let status: Int?

    static func xml(_ value: String, status: Int = 200) -> ExchangeReply {
        ExchangeReply(data: Data(value.utf8), status: status)
    }
}

private final class ExchangeFixture {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []
    private let replies: [ExchangeReply]
    private let host = "\(UUID().uuidString.lowercased()).invalid"
    private let session: URLSession
    private let mode: ExchangeTLSMode

    init(replies: [ExchangeReply], mode: ExchangeTLSMode = .systemTrust) {
        self.replies = replies
        self.mode = mode
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExchangeMockProtocol.self]
        session = URLSession(configuration: configuration)
        ExchangeMockProtocol.register(host: host) { [weak self] request in self?.reply(to: request) }
    }

    deinit {
        session.invalidateAndCancel()
        ExchangeMockProtocol.unregister(host: host)
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func fetch() async throws -> [Meeting] {
        let settings = ExchangeSettings(serverURL: "\(mode == .insecureWarning ? "http" : "https")://\(host)", port: mode == .insecureWarning ? 80 : 443, username: "test", tlsMode: mode)
        let provider = EWSCalendarProvider(settings: settings, password: "test-password", session: session)
        return try await provider.fetchMeetings(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 3600))
    }

    private func reply(to request: URLRequest) -> ExchangeReply? {
        lock.lock()
        defer { lock.unlock() }
        var captured = request
        captured.httpBody = Data(ExchangeMockProtocol.body(request).utf8)
        recordedRequests.append(captured)
        let index = recordedRequests.count - 1
        guard replies.indices.contains(index) else {
            XCTFail("Unexpected extra Exchange request")
            return nil
        }
        return replies[index]
    }
}

private final class ExchangeMockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) -> ExchangeReply?] = [:]

    static func register(host: String, handler: @escaping (URLRequest) -> ExchangeReply?) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
    }

    static func unregister(host: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: host)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers[request.url?.host ?? ""]
        Self.lock.unlock()
        guard let reply = handler?(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response: URLResponse
        if let status = reply.status {
            response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/xml"])!
        } else {
            response = URLResponse(url: url, mimeType: "text/xml", expectedContentLength: reply.data.count, textEncodingName: "utf-8")
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
