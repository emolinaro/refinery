import Foundation

/// Orchestrates the codex CLI's ChatGPT login for Refinery: reads
/// `~/.codex/auth.json` read-only, refreshes via the codex CLI's own OAuth
/// endpoint when the access token is at or past expiry, and persists the
/// refreshed tokens back so the CLI and Refinery share one login session.
///
/// Token material never appears in errors, logs, or UI. The account line
/// (email, plan, last refresh) comes from the id_token claims, which are not
/// secrets.
///
/// A refresh is only attempted when the store is definitively expired: the
/// refresh token is single-use, so a speculative exchange could invalidate a
/// session a running codex CLI is about to use.
struct ChatGPTSession: Sendable {
    /// A ready-to-use bearer credential.
    struct Credential: Equatable, Sendable {
        var accessToken: String
        var accountID: String?
    }

    /// Non-secret account state for the Settings UI.
    struct AccountSummary: Equatable, Sendable {
        var email: String?
        var planType: String?
        var lastRefresh: Date?

        /// True when the codex CLI is signed in with a ChatGPT account.
        var signedIn: Bool { email != nil || planType != nil }
    }

    enum SessionError: LocalizedError, Equatable {
        /// The access token is expired and the refresh exchange failed.
        case refreshFailed(String)

        var errorDescription: String? {
            switch self {
            case .refreshFailed(let message):
                return message
            }
        }
    }

    static let refreshSkew: TimeInterval = 30

    let store: CodexAuthStore
    let refresher: OAuthTokenRefresher
    private let now: @Sendable () -> Date

    init(
        store: CodexAuthStore = CodexAuthStore(),
        refresher: OAuthTokenRefresher = OAuthTokenRefresher(),
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.refresher = refresher
        self.now = now
    }

    /// Reads the store and refreshes if the access token is expired or
    /// missing. Returns the credential plus the (possibly updated) store.
    nonisolated func validCredential() async throws -> (credential: Credential, store: CodexAuthFile) {
        var file = try store.loadChatGPTTokens()
        if let accessToken = file.tokens?.accessToken, !Self.isExpired(accessToken, now: now()) {
            return (Credential(accessToken: accessToken, accountID: file.tokens?.accountId), file)
        }

        guard let refreshToken = file.tokens?.refreshToken,
              !refreshToken.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CodexAuthStoreError.missingTokens
        }

        let refreshed: OAuthTokenRefresher.RefreshedTokens
        do {
            refreshed = try await refresher.refresh(refreshToken: refreshToken)
        } catch {
            throw SessionError.refreshFailed(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        file.tokens?.accessToken = refreshed.accessToken
        if let idToken = refreshed.idToken {
            file.tokens?.idToken = idToken
        }
        file.tokens?.refreshToken = refreshed.refreshToken
        file.lastRefresh = ISO8601DateFormatter().string(from: now())
        do {
            try store.persist(file)
        } catch {
            // The polish request can still proceed with the fresh access
            // token even though the rotation was not persisted; the next run
            // will fail its refresh and the CLI will ask for a new login.
        }
        return (Credential(accessToken: refreshed.accessToken, accountID: file.tokens?.accountId), file)
    }

    /// Non-secret account summary for the Settings UI; never throws.
    func accountSummary() -> AccountSummary {
        guard let file = try? store.loadChatGPTTokens() else {
            return AccountSummary(email: nil, planType: nil, lastRefresh: nil)
        }
        let identity = file.tokens?.idToken.flatMap { token in
            try? JWTClaims.decode(token)
        }?.identity
        return AccountSummary(
            email: identity?.email,
            planType: identity?.planType,
            lastRefresh: Self.parseLastRefresh(file.lastRefresh)
        )
    }

    static func isExpired(_ accessToken: String, now: Date) -> Bool {
        guard let claims = try? JWTClaims.decode(accessToken),
              let expiration = claims.expiration else {
            return true
        }
        return expiration.timeIntervalSince(now) <= refreshSkew
    }

    static func parseLastRefresh(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        return plain.date(from: raw)
    }
}
