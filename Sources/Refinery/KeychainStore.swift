import Foundation
import Security

/// Stores and reads the endpoint API key in the macOS Keychain.
///
/// The key never lives in plain files or UserDefaults; only a Keychain item
/// with a service/account pair scoped to the endpoint host. All access goes
/// through this type so reading code never handles raw key bytes outside a request.
enum KeychainStore {
    private static let service = "com.refinery.app.endpoint-key"
    typealias CopyMatching = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    enum KeychainError: LocalizedError {
        case invalidHost
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidHost:
                return "The endpoint does not have a valid host."
            case .unexpectedStatus(let status):
                return "Keychain operation failed (status \(status))."
            }
        }
    }

    /// Saves (creates or updates) the API key for the endpoint host.
    static func saveAPIKey(_ key: String, for baseURL: URL) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)
        guard let account = account(for: baseURL) else { throw KeychainError.invalidHost }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Update the existing item if present; otherwise create it.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Reads the saved API key for the endpoint host, if any.
    static func readAPIKey(
        for baseURL: URL,
        copyMatching: CopyMatching = SecItemCopyMatching
    ) throws -> String? {
        guard let account = account(for: baseURL) else { throw KeychainError.invalidHost }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedStatus(errSecDecode)
        }
        return key
    }

    private static func account(for baseURL: URL) -> String? {
        guard let host = baseURL.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }
}
