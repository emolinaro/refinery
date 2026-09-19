import Foundation
import Combine

/// The app's reference to the codex CLI login. Holds no token material: only
/// the non-secret account summary, plus a sign-out affordance that clears
/// Refinery's reference while leaving the CLI's own auth.json untouched.
@MainActor
final class SubscriptionAccountController: ObservableObject {
    @Published private(set) var account: ChatGPTSession.AccountSummary

    private let session: ChatGPTSession
    /// A nonisolated copy for credential fetches: file I/O and network
    /// flight stay off the main actor, matching the endpoint path's detached
    /// selection read.
    private nonisolated let detachedSession: ChatGPTSession
    /// Remembers whether the user signed out in this app: the summary stays
    /// empty even while the CLI's own login remains on disk.
    private var signedOutInApp = false

    init(session: ChatGPTSession = ChatGPTSession()) {
        self.session = session
        self.account = session.accountSummary()
        self.detachedSession = session
    }

    /// True when the codex CLI's login is usable by Refinery.
    var isSignedIn: Bool {
        !signedOutInApp && account.signedIn
    }

    /// True when the codex CLI's login is present on disk, ignoring this
    /// app's own sign-out state (used to offer a fresh reference).
    var loginExistsOnDisk: Bool {
        session.accountSummary().signedIn
    }

    /// Re-reads the non-secret account state. Called when Settings opens or
    /// the provider picker changes.
    func refreshAccountState() {
        guard !signedOutInApp else { return }
        account = session.accountSummary()
    }

    /// Drops Refinery's reference to the shared login. Never touches
    /// `~/.codex/auth.json` - the codex CLI keeps its own session.
    func signOut() {
        signedOutInApp = true
        account = ChatGPTSession.AccountSummary(email: nil, planType: nil, lastRefresh: nil)
    }

    /// Re-adopts the CLI's on-disk login after an explicit sign-out.
    func adoptExistingLogin() {
        signedOutInApp = false
        refreshAccountState()
    }

    /// The credential used for a polish request. Bypassed by the in-app
    /// sign-out gate even though the file remains on disk.
    func credential() async throws -> ChatGPTSession.Credential {
        guard !signedOutInApp else {
            throw SubscriptionError.session(
                "Refinery is signed out of the OpenAI subscription. Sign in from Settings."
            )
        }
        return try await detachedSession.validCredential().credential
    }
}
