import Foundation
import Security
import MeetingJoinerCore

struct KeychainStore {
    private static let service = "com.qrpeachkz.meeting-joiner"

    static func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.status(status) }
        } else if update != errSecSuccess {
            throw KeychainError.status(update)
        }
    }

    static func load(account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return result as? Data
    }

    static func saveSecret(_ value: String, account: String) throws {
        try save(Data(value.utf8), account: account)
    }

    static func loadSecret(account: String) throws -> String? {
        try load(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    static func importCACertificate(from fileURL: URL, label: String) throws {
        var data = try Data(contentsOf: fileURL)
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
            let base64 = text.components(separatedBy: .newlines)
                .filter { !$0.hasPrefix("-----") }
                .joined()
            guard let decoded = Data(base64Encoded: base64) else { throw KeychainError.invalidCertificate }
            data = decoded
        }
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else { throw KeychainError.invalidCertificate }
        deleteCertificate(label: label)
        let status = SecItemAdd([kSecClass as String: kSecClassCertificate,
                                 kSecValueRef as String: certificate,
                                 kSecAttrLabel as String: label] as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func importClientIdentity(from fileURL: URL, passphrase: String) throws -> String {
        let data = try Data(contentsOf: fileURL)
        var result: CFArray?
        let status = SecPKCS12Import(data as CFData,
                                     [kSecImportExportPassphrase as String: passphrase] as CFDictionary,
                                     &result)
        guard status == errSecSuccess,
              let entries = result as? [[String: Any]],
              let entry = entries.first,
              let identityValue = entry[kSecImportItemIdentity as String] else {
            throw KeychainError.status(status)
        }
        let identity = identityValue as! SecIdentity
        let label = (entry[kSecImportItemLabel as String] as? String) ?? "Meeting Joiner EWS Client Certificate"
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess else { throw KeychainError.invalidCertificate }
        return label
    }

    static func certificate(label: String) -> SecCertificate? {
        let query: [String: Any] = [kSecClass as String: kSecClassCertificate,
                                    kSecAttrLabel as String: label,
                                    kSecReturnRef as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as! SecCertificate)
    }

    static func identity(label: String) -> SecIdentity? {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity,
                                    kSecAttrLabel as String: label,
                                    kSecReturnRef as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as! SecIdentity)
    }

    private static func deleteCertificate(label: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label]
        SecItemDelete(query as CFDictionary)
    }
}

struct KeychainGoogleTokenStore: GoogleTokenStoring {
    private let account = "google.oauth-token"
    func loadToken() throws -> GoogleOAuthToken? {
        guard let data = try KeychainStore.load(account: account) else { return nil }
        return try JSONDecoder().decode(GoogleOAuthToken.self, from: data)
    }
    func saveToken(_ token: GoogleOAuthToken) throws {
        try KeychainStore.save(JSONEncoder().encode(token), account: account)
    }
}

enum KeychainError: Error, LocalizedError {
    case status(OSStatus)
    case invalidCertificate
    var errorDescription: String? {
        switch self {
        case .status(let status): return "Keychain operation failed (status \(status))."
        case .invalidCertificate: return "The selected file is not a valid certificate or PKCS#12 identity."
        }
    }
}
