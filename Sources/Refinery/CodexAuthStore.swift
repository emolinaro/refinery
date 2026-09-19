import Foundation

/// The codex CLI's ChatGPT login store (`~/.codex/auth.json`), read with the
/// same read-only discipline as quota readers: the file is the CLI's own
/// credential store and this type treats it as shared session state.
///
/// JSON shape (field names are the codex CLI's, not ours):
/// {
///   "auth_mode": "chatgpt",
///   "OPENAI_API_KEY": null,
///   "tokens": {
///     "id_token": "<JWT>",
///     "access_token": "<JWT>",
///     "refresh_token": "<opaque>",
///     "account_id": "<uuid>"
///   },
///   "last_refresh": "2026-09-15T06:21:29.664762Z"
/// }
///
/// Token material never appears in error descriptions, logs, or UI; only the
/// non-secret account state (email, plan, last refresh) derived from the
/// id_token claims is surfaced.
struct CodexAuthFile: Codable, Equatable, Sendable {
    struct Tokens: Codable, Equatable, Sendable {
        var idToken: String?
        var accessToken: String?
        var refreshToken: String?
        var accountId: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case accountId = "account_id"
        }
    }

    var authMode: String?
    var tokens: Tokens?
    var lastRefresh: String?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case tokens
        case lastRefresh = "last_refresh"
    }
}

enum CodexAuthStoreError: LocalizedError, Equatable {
    /// auth.json exists but auth_mode is not "chatgpt" (e.g. an API-key login
    /// owns the file right now).
    case notChatGPTLogin
    /// The file is missing, unreadable, or malformed.
    case unreadableStore(String)
    /// The ChatGPT tokens are absent or incomplete.
    case missingTokens
    /// The store could not be persisted after a refresh.
    case storeWriteFailed

    var errorDescription: String? {
        switch self {
        case .notChatGPTLogin:
            return
                "The codex CLI is not signed in with a ChatGPT account. Run `codex login` in a terminal, then try again."
        case .unreadableStore:
            return
                "The codex CLI login could not be read. Run `codex login` in a terminal, then try again."
        case .missingTokens:
            return
                "The codex CLI login is incomplete. Run `codex login` in a terminal, then try again."
        case .storeWriteFailed:
            return
                "The refreshed codex login could not be saved back to the codex CLI's store."
        }
    }
}

/// Reads and - after an OAuth refresh - writes back the codex CLI's
/// `auth.json`, so the CLI and Refinery share one login session.
///
/// All paths flow through injected closures so tests never touch the real
/// `~/.codex` directory.
struct CodexAuthStore: Sendable {
    /// Bound limit on the auth file: the real file is a few kilobytes.
    static let maximumFileBytes = 64 * 1024

    /// Non-secret account state derived from the id_token claims.
    struct AccountState: Equatable, Sendable {
        var email: String?
        var planType: String?
        var lastRefresh: Date?
    }

    typealias FileReader = @Sendable (URL) throws -> Data
    typealias FileWriter = @Sendable (URL, Data) throws -> Void
    typealias FilePresence = @Sendable (URL) -> Bool

    let fileURL: URL
    let read: FileReader
    let write: FileWriter
    let exists: FilePresence

    init(
        fileURL: URL? = nil,
        read: @escaping FileReader = CodexAuthStore.defaultRead,
        write: @escaping FileWriter = CodexAuthStore.defaultWrite,
        exists: @escaping FilePresence = CodexAuthStore.defaultExists
    ) {
        self.fileURL = fileURL ?? CodexAuthStore.defaultFileURL()
        self.read = read
        self.write = write
        self.exists = exists
    }

    static func defaultFileURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        }
        return home.appendingPathComponent(".codex/auth.json")
    }

    private static func defaultRead(_ url: URL) throws -> Data {
        try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func defaultWrite(_ url: URL, _ data: Data) throws {
        try data.write(to: url, options: [.atomic])
    }

    private static func defaultExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Reads the raw parsed store; throws a `CodexAuthStoreError` on any
    /// structural problem. Token values never enter the thrown errors.
    func load() throws -> CodexAuthFile {
        let data: Data
        do {
            data = try read(fileURL)
        } catch {
            throw CodexAuthStoreError.unreadableStore("read failed")
        }
        guard data.count <= Self.maximumFileBytes else {
            throw CodexAuthStoreError.unreadableStore("oversized")
        }
        do {
            return try JSONDecoder().decode(CodexAuthFile.self, from: data)
        } catch {
            throw CodexAuthStoreError.unreadableStore("undecodable")
        }
    }

    /// Reads the store and validates it carries a ChatGPT login with tokens.
    func loadChatGPTTokens() throws -> CodexAuthFile {
        let store = try load()
        guard store.authMode == "chatgpt" else {
            throw CodexAuthStoreError.notChatGPTLogin
        }
        let tokens = store.tokens
        guard let tokens,
              !(tokens.accessToken ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
              !(tokens.refreshToken ?? "").trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CodexAuthStoreError.missingTokens
        }
        return store
    }

    /// Persists a store back to auth.json, preserving unknown fields (the
    /// codex CLI may add its own) by decoding the file as a dictionary.
    /// Writes atomically so the CLI never observes a torn file.
    func persist(_ store: CodexAuthFile) throws {
        let raw = (try? JSONSerialization.jsonObject(with: (try? read(fileURL)) ?? Data())) as? [String: Any] ?? [:]
        var merged = raw
        merged["auth_mode"] = store.authMode
        merged["last_refresh"] = store.lastRefresh
        var tokens = (raw["tokens"] as? [String: Any]) ?? [:]
        tokens["id_token"] = store.tokens?.idToken
        tokens["access_token"] = store.tokens?.accessToken
        tokens["refresh_token"] = store.tokens?.refreshToken
        tokens["account_id"] = store.tokens?.accountId
        // Drop nulls the CLI would not persist itself.
        for (key, value) in tokens where value is NSNull {
            tokens.removeValue(forKey: key)
        }
        merged["tokens"] = tokens

        let data: Data
        do {
            if JSONSerialization.isValidJSONObject(merged),
               let encoded = try? JSONSerialization.data(
                   withJSONObject: merged,
                   options: [.prettyPrinted, .sortedKeys]
               ) {
                data = encoded
            } else {
                data = try JSONEncoder().encode(store)
            }
        } catch {
            throw CodexAuthStoreError.storeWriteFailed
        }
        do {
            try write(fileURL, data)
        } catch {
            throw CodexAuthStoreError.storeWriteFailed
        }
    }
}
