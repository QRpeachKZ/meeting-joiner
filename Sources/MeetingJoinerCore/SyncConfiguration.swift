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
              components.host?.isEmpty == false else { throw ExchangeSettingsError.invalidServerURL }
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
        let login = domain.isEmpty ? username : "\(domain)\\\(username)"
        return "Basic " + Data("\(login):\(password)".utf8).base64EncodedString()
    }
}

public enum ExchangeSettingsError: Error, LocalizedError {
    case invalidPort
    case invalidSyncInterval
    case invalidServerURL
    case tlsModeMismatch
    case missingCustomCA

    public var errorDescription: String? {
        switch self {
        case .invalidPort: return "Port must be between 1 and 65535."
        case .invalidSyncInterval: return "Sync interval must be between 1 and 1440 minutes."
        case .invalidServerURL: return "Enter a valid Exchange server URL."
        case .tlsModeMismatch: return "Use HTTPS with certificate validation, or explicitly select no-TLS mode with an HTTP URL."
        case .missingCustomCA: return "Select a CA certificate from Keychain before using custom CA mode."
        }
    }
}
