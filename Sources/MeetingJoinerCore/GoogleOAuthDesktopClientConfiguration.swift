import Foundation

/// A Google OAuth Desktop client configuration loaded from a local project file.
/// The values are intentionally not Codable or printable and are never persisted by this type.
public struct GoogleOAuthDesktopClientConfiguration: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "GoogleOAuthDesktopClientConfiguration(<redacted>)" }
    public var debugDescription: String { description }

    public let clientID: String
    public let clientSecret: String

    public init?(data: Data) {
        guard let document = try? JSONDecoder().decode(GoogleOAuthDesktopClientDocument.self, from: data),
              let client = document.installed else { return nil }

        let clientID = client.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = client.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clientID.hasSuffix(".apps.googleusercontent.com"),
              clientID.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !clientSecret.isEmpty else { return nil }

        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// Searches only the project root, and only direct files matching Google's downloaded filename pattern.
    /// Malformed candidates are skipped so they can fall back to manual configuration.
    public static func discover(inProjectDirectory projectDirectory: URL,
                                fileManager: FileManager = .default) -> Self? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = files.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("client_secret") && name.hasSuffix(".json")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for candidate in candidates {
            guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: candidate, options: [.mappedIfSafe]),
                  let configuration = Self(data: data) else { continue }
            return configuration
        }
        return nil
    }

    /// Finds the nearest package root above any app/executable directory, allowing the bundled app to
    /// work when launched by Finder with an unrelated current working directory.
    public static func projectRoot(containingPackageFrom searchDirectories: [URL],
                                   fileManager: FileManager = .default) -> URL? {
        for searchDirectory in searchDirectories {
            var candidate = searchDirectory.standardizedFileURL
            while true {
                if fileManager.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
                    return candidate
                }
                let parent = candidate.deletingLastPathComponent()
                guard parent.path != candidate.path else { break }
                candidate = parent
            }
        }
        return nil
    }
}

private struct GoogleOAuthDesktopClientDocument: Decodable {
    let installed: GoogleOAuthDesktopClient?
}

private struct GoogleOAuthDesktopClient: Decodable {
    let clientID: String
    let clientSecret: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }
}
