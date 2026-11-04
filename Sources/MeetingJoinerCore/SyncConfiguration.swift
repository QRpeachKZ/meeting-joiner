import Foundation

public enum ExchangeTLSMode: String, Codable, CaseIterable, Sendable {
    case systemTrust
    case customCA
    case insecureWarning

    public var displayName: String {
        switch self {
        case .systemTrust: return "System CA validation"
        case .customCA: return "System CA plus configured CA"
        case .insecureWarning: return "No TLS (unsafe; password authentication disabled)"
        }
    }
}

public struct ExchangeSettings: Codable, Equatable, Sendable {
    public var serverURL: String
    public var port: Int
    public var domain: String
    public var username: String
    public var syncIntervalMinutes: Int
    public var tlsMode: ExchangeTLSMode
    public var customCALabel: String?
    public var clientIdentityLabel: String?

    public init(
        serverURL: String = "https://exchange.example.com",
        port: Int = 443,
        domain: String = "",
        username: String = "",
        syncIntervalMinutes: Int = 5,
        tlsMode: ExchangeTLSMode = .systemTrust,
        customCALabel: String? = nil,
        clientIdentityLabel: String? = nil
    ) {
        self.serverURL = serverURL
        self.port = port
        self.domain = domain
        self.username = username
        self.syncIntervalMinutes = syncIntervalMinutes
        self.tlsMode = tlsMode
        self.customCALabel = customCALabel
        self.clientIdentityLabel = clientIdentityLabel
    }

    public var login: String {
        domain.isEmpty ? username : "\(domain)\\\(username)"
    }

    public mutating func setLogin(_ raw: String) throws {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            domain = ""
            username = ""
            return
        }
        let parts = value.components(separatedBy: "\\")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ExchangeSettingsError.invalidLogin
        }
        domain = parts[0]
        username = parts[1]
    }

    public var securityWarning: String? {
        tlsMode == .insecureWarning
            ? "Warning: EWS traffic is unencrypted. Saving this mode removes the saved password and disables password authentication; Exchange may reject this connection."
            : nil
    }

    public func validate() throws {
        guard (1...65_535).contains(port) else { throw ExchangeSettingsError.invalidPort }
        guard (1...1_440).contains(syncIntervalMinutes) else { throw ExchangeSettingsError.invalidSyncInterval }
        guard let components = URLComponents(string: serverURL),
              let scheme = components.scheme?.lowercased(),
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw ExchangeSettingsError.invalidServerURL }
        switch tlsMode {
        case .systemTrust, .customCA:
            guard scheme == "https" else { throw ExchangeSettingsError.tlsModeMismatch }
        case .insecureWarning:
            guard scheme == "http" else { throw ExchangeSettingsError.tlsModeMismatch }
        }
        if tlsMode == .customCA, customCALabel?.isEmpty != false {
            throw ExchangeSettingsError.missingCustomCA
        }
    }

    public func endpointURL() throws -> URL {
        try validate()
        guard var components = URLComponents(string: serverURL) else { throw ExchangeSettingsError.invalidServerURL }
        components.port = port
        if components.path.isEmpty || components.path == "/" {
            components.path = "/EWS/Exchange.asmx"
        }
        guard let url = components.url else { throw ExchangeSettingsError.invalidServerURL }
        return url
    }

    public func authorizationHeader(password: String) -> String? {
        guard tlsMode != .insecureWarning, !username.isEmpty, !password.isEmpty else { return nil }
        return "Basic " + Data("\(login):\(password)".utf8).base64EncodedString()
    }

    public func allowsRedirect(from source: URL, to target: URL) -> Bool {
        guard let origin = try? endpointURL() else { return false }
        return Self.sameOrigin(source, origin) && Self.sameOrigin(target, origin)
    }

    public func allowsClientIdentity(host: String, port: Int, scheme: String?) -> Bool {
        guard tlsMode != .insecureWarning, let origin = try? endpointURL(),
              origin.scheme?.lowercased() == "https", scheme?.lowercased() == "https" else { return false }
        return host.lowercased() == origin.host?.lowercased() && port == (origin.port ?? 443)
    }

    private static func sameOrigin(_ url: URL, _ origin: URL) -> Bool {
        let scheme = origin.scheme?.lowercased()
        let defaultPort = scheme == "https" ? 443 : 80
        return url.user == nil && url.password == nil
            && url.scheme?.lowercased() == scheme
            && url.host?.lowercased() == origin.host?.lowercased()
            && (url.port ?? defaultPort) == (origin.port ?? defaultPort)
    }
}

public enum ExchangeSettingsError: Error, LocalizedError {
    case invalidPort
    case invalidSyncInterval
    case invalidServerURL
    case tlsModeMismatch
    case missingCustomCA
    case invalidLogin

    public var errorDescription: String? {
        switch self {
        case .invalidLogin: return "Введите логин в формате DOMAIN\\USERNAME (например, MOSCOW\\U_M1ABC) или оставьте поле пустым, чтобы отключить Exchange."
        case .invalidPort: return "Port must be between 1 and 65535."
        case .invalidSyncInterval: return "Sync interval must be between 1 and 1440 minutes."
        case .invalidServerURL: return "Enter a valid Exchange server URL."
        case .tlsModeMismatch: return "Use HTTPS with certificate validation, or explicitly select no-TLS mode with an HTTP URL."
        case .missingCustomCA: return "Select a CA certificate from Keychain before using custom CA mode."
        }
    }
}
