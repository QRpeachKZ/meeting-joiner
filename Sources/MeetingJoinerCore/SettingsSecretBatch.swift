import Foundation

public struct SettingsSecretUpdate: Sendable {
    public let account: String
    public let value: Data?

    public init(account: String, value: Data?) {
        self.account = account
        self.value = value
    }
}

public enum SettingsSecretBatch {
    public static func apply(_ updates: [SettingsSecretUpdate],
                             load: (String) throws -> Data?,
                             write: (Data?, String) throws -> Void) throws -> Bool {
        let originals = try updates.map { try load($0.account) }
        let changed = updates.indices.filter { updates[$0].value != originals[$0] }
        var applied: [Int] = []
        do {
            for index in changed {
                try write(updates[index].value, updates[index].account)
                applied.append(index)
            }
        } catch {
            let updateError = error
            var rollbackFailed = false
            for index in applied.reversed() {
                do {
                    try write(originals[index], updates[index].account)
                } catch {
                    rollbackFailed = true
                }
            }
            if rollbackFailed { throw SettingsSecretBatchError.rollbackFailed }
            throw updateError
        }
        return !changed.isEmpty
    }
}

public enum SettingsSecretBatchError: Error, LocalizedError {
    case rollbackFailed

    public var errorDescription: String? {
        "Secret update failed and rollback was incomplete; saved secrets may have changed. Re-enter and save both secrets."
    }
}
