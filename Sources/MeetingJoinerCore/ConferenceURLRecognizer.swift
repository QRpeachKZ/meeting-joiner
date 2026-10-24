import Foundation

public enum ConferenceURLRecognizer {
    private static let allowedHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "bluejeans.com"
    ]

    public static func firstURL(in text: String) -> URL? {
        guard let expression = try? NSRegularExpression(pattern: "https?://[^\\s<>\\\"']+", options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let candidate = String(text[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
            guard let components = URLComponents(string: candidate),
                  components.scheme?.lowercased() == "https",
                  let host = components.host?.lowercased(),
                  isConferenceHost(host),
                  let url = components.url else { continue }
            return url
        }
        return nil
    }

    private static func isConferenceHost(_ host: String) -> Bool {
        allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
