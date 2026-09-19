import XCTest
@testable import Refinery

// MARK: - Test JWT helpers

/// Thread-safe counter for concurrent-capture assertions.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

/// Thread-safe request capture for transport tests.
private final class LockedRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    func set(_ value: URLRequest?) {
        lock.lock()
        request = value
        lock.unlock()
    }
    func get() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }
}

/// An `HTTPURLResponse` subclass that reports the canned body's length for
/// a byte stream the (unstreamed) test transport returns.
private final class CachedHTTPResponse: HTTPURLResponse, @unchecked Sendable {
    private let byteCount: Int64

    init(status: Int, url: URL, bytes: Data) {
        self.byteCount = Int64(bytes.count)
        super.init(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var expectedContentLength: Int64 {
        byteCount
    }
}

/// Builds a compact unsigned JWT with the given claims; test-only, for
/// expiry and identity decoding paths.
private func makeJWT(expiration: Date? = nil, email: String? = nil, plan: String? = nil) -> String {    func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var claims: [String: Any] = [:]
    if let expiration {
        claims["exp"] = expiration.timeIntervalSince1970
    }
    if let email {
        claims["email"] = email
    }
    if let plan {
        claims["https://api.openai.com/auth"] = ["chatgpt_plan_type": plan]
    }
    let header = base64URL(Data("{\"alg\":\"none\"}".utf8))
    let payload = base64URL(
        (try! JSONSerialization.data(withJSONObject: claims))
    )
    return "\(header).\(payload).signature"
}

/// A deterministic ChatGPT-login-shaped auth.json fixture.
private func makeAuthJSON(
    accessToken: String,
    refreshToken: String = "rt-refresh-token",
    idToken: String? = nil,
    accountID: String = "account-123",
    lastRefresh: String? = "2026-09-15T06:21:29.664762Z"
) -> Data {
    var tokens: [String: Any] = [
        "access_token": accessToken,
        "refresh_token": refreshToken,
        "account_id": accountID,
    ]
    if let idToken {
        tokens["id_token"] = idToken
    }
    var file: [String: Any] = [
        "auth_mode": "chatgpt",
        "OPENAI_API_KEY": NSNull(),
        "tokens": tokens,
    ]
    if let lastRefresh {
        file["last_refresh"] = lastRefresh
    }
    return try! JSONSerialization.data(withJSONObject: file)
}

// MARK: - JWTClaims

final class JWTClaimsTests: XCTestCase {
    func testDecodesExpirationAndIdentity() throws {
        let expiration = Date(timeIntervalSince1970: 1_790_317_289)
        let token = makeJWT(expiration: expiration, email: "user@example.com", plan: "prolite")
        let claims = try JWTClaims.decode(token)
        XCTAssertEqual(claims.expiration, expiration)
        XCTAssertEqual(claims.identity.email, "user@example.com")
        XCTAssertEqual(claims.identity.planType, "prolite")
    }

    func testRejectsMalformedTokens() {
        for malformed in ["", "not-a-jwt", "a.b", "a.b.c.d"] {
            XCTAssertThrowsError(try JWTClaims.decode(malformed))
        }
    }
}

// MARK: - CodexAuthStore

final class CodexAuthStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("refinery-tests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func makeStore(data: Data?) -> CodexAuthStore {
        if let data {
            try! data.write(to: fileURL)
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return CodexAuthStore(fileURL: fileURL)
    }

    func testLoadChatGPTTokensReadsTheStore() throws {
        let token = makeJWT()
        let store = makeStore(data: makeAuthJSON(accessToken: token))
        let file = try store.loadChatGPTTokens()
        XCTAssertEqual(file.authMode, "chatgpt")
        XCTAssertEqual(file.tokens?.accessToken, token)
        XCTAssertEqual(file.tokens?.refreshToken, "rt-refresh-token")
        XCTAssertEqual(file.tokens?.accountId, "account-123")
    }

    func testNonChatGPTLoginIsRejected() {
        let store = makeStore(data: Data(#"{"auth_mode":"apikey","tokens":{"access_token":"a","refresh_token":"b"}}"#.utf8))
        XCTAssertThrowsError(try store.loadChatGPTTokens()) { error in
            XCTAssertEqual(error as? CodexAuthStoreError, .notChatGPTLogin)
        }
    }

    func testMissingTokensAreRejected() {
        for payload in [
            #"{"auth_mode":"chatgpt"}"#,
            #"{"auth_mode":"chatgpt","tokens":{}}"#,
            #"{"auth_mode":"chatgpt","tokens":{"access_token":"  ","refresh_token":"b"}}"#,
        ] {
            let store = makeStore(data: Data(payload.utf8))
            XCTAssertThrowsError(try store.loadChatGPTTokens()) { error in
                XCTAssertEqual(error as? CodexAuthStoreError, .missingTokens)
            }
        }
    }

    func testMalformedFileIsRejected() {
        let store = makeStore(data: Data("not json".utf8))
        XCTAssertThrowsError(try store.loadChatGPTTokens())
    }

    func testOversizedFileIsRejected() {
        var huge = makeAuthJSON(accessToken: makeJWT())
        huge += Data(repeating: 0x20, count: CodexAuthStore.maximumFileBytes)
        let store = makeStore(data: huge)
        XCTAssertThrowsError(try store.loadChatGPTTokens())
    }

    func testPersistRotatesTokensAndPreservesUnknownFields() throws {
        let unknown = makeAuthJSON(accessToken: makeJWT())
        var original = (try! JSONSerialization.jsonObject(with: unknown)) as! [String: Any]
        original["future_cli_field"] = "keep-me"
        let store = makeStore(data: try! JSONSerialization.data(withJSONObject: original))

        var file = try store.loadChatGPTTokens()
        file.tokens?.accessToken = "new-access"
        file.tokens?.refreshToken = "new-refresh"
        file.lastRefresh = "2026-09-20T00:00:00Z"
        try store.persist(file)

        let reread = try store.loadChatGPTTokens()
        XCTAssertEqual(reread.tokens?.accessToken, "new-access")
        XCTAssertEqual(reread.tokens?.refreshToken, "new-refresh")
        XCTAssertEqual(reread.lastRefresh, "2026-09-20T00:00:00Z")

        let raw = (try! JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))) as! [String: Any]
        XCTAssertEqual(raw["future_cli_field"] as? String, "keep-me")
    }

    func testPersistFailsCleanlyWhenUnwritable() throws {
        let store = makeStore(data: makeAuthJSON(accessToken: makeJWT()))
        let unwritable = CodexAuthStore(
            fileURL: fileURL,
            read: { url in try Data(contentsOf: url) },
            write: { _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        var file = try store.loadChatGPTTokens()
        file.tokens?.accessToken = "rotated"
        XCTAssertThrowsError(try unwritable.persist(file)) { error in
            XCTAssertEqual(error as? CodexAuthStoreError, .storeWriteFailed)
        }
    }
}

// MARK: - OAuthTokenRefresher

final class OAuthTokenRefresherTests: XCTestCase {
    func testRefreshPostsFormEncodedBodyToTheCodexEndpoint() async throws {
        let capturedRequest = LockedRequestBox()
        let transport: OAuthTokenRefresher.Transport = { request in
            capturedRequest.set(request)
            let body = """
            {"access_token":"new-access","id_token":"new-id","refresh_token":"new-refresh","expires_in":3600}
            """
            return (
                Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let refresher = OAuthTokenRefresher(transport: transport)

        let refreshed = try await refresher.refresh(refreshToken: "rt-old")

        XCTAssertEqual(refreshed.accessToken, "new-access")
        XCTAssertEqual(refreshed.idToken, "new-id")
        XCTAssertEqual(refreshed.refreshToken, "new-refresh")
        XCTAssertEqual(refreshed.expiresInSeconds, 3600)

        let request = try XCTUnwrap(capturedRequest.get())
        XCTAssertEqual(request.url, OAuthTokenRefresher.tokenEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let fields = body.split(separator: "&").map(String.init).sorted()
        XCTAssertTrue(fields.contains("grant_type=refresh_token"))
        XCTAssertTrue(fields.contains("client_id=\(OAuthTokenRefresher.clientID)"))
        XCTAssertTrue(fields.contains("refresh_token=rt-old"))
        // The response body is the only place the new tokens appear.
        XCTAssertFalse(body.contains("new-access"))
    }

    func testRefreshSurfacesHTTPRejectionWithoutTheBody() async {
        let transport: OAuthTokenRefresher.Transport = { request in
            (
                Data("refresh token revoked for rt-old".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            )
        }
        let refresher = OAuthTokenRefresher(transport: transport)

        do {
            _ = try await refresher.refresh(refreshToken: "rt-old")
            XCTFail("expected httpStatus")
        } catch let error as OAuthTokenRefresher.RefreshError {
            XCTAssertEqual(error, .httpStatus(400))
            XCTAssertFalse(error.localizedDescription.contains("rt-old"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRefreshRejectsIncompleteResponses() async {
        for payload in [
            #"{"access_token":"a"}"#,
            #"{"access_token":"a","refresh_token":"r"}"#,
            #"{"access_token":"a","refresh_token":"r","expires_in":0}"#,
            #"{"access_token":"","refresh_token":"r","expires_in":60}"#,
        ] {
            let transport: OAuthTokenRefresher.Transport = { request in
                (
                    Data(payload.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
            let refresher = OAuthTokenRefresher(transport: transport)
            do {
                _ = try await refresher.refresh(refreshToken: "rt-old")
                XCTFail("expected invalidResponse for \(payload)")
            } catch let error as OAuthTokenRefresher.RefreshError {
                XCTAssertEqual(error, .invalidResponse)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }
}

// MARK: - ChatGPTSession (refresh flow)

final class ChatGPTSessionTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("refinery-tests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func writeAuth(_ data: Data) -> CodexAuthStore {
        try! data.write(to: fileURL)
        return CodexAuthStore(fileURL: fileURL)
    }

    private func makeSession(
        store: CodexAuthStore,
        now: Date = Date(),
        transport: @escaping OAuthTokenRefresher.Transport = { request in
            let body = """
            {"access_token":"new-access","id_token":"new-id","refresh_token":"new-refresh","expires_in":3600}
            """
            return (
                Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
    ) -> ChatGPTSession {        ChatGPTSession(
            store: store,
            refresher: OAuthTokenRefresher(transport: transport),
            now: { now }
        )
    }

    func testFreshAccessTokenIsUsedWithoutRefresh() async throws {
        let future = Date().addingTimeInterval(3600)
        let accessToken = makeJWT(expiration: future)
        let refreshCalls = LockedCounter()
        let session = makeSession(
            store: writeAuth(makeAuthJSON(accessToken: accessToken)),
            transport: { _ in
                refreshCalls.increment()
                XCTFail("refresh must not run for a fresh token")
                throw OAuthTokenRefresher.RefreshError.network("unreachable")
            }
        )

        let (credential, _) = try await session.validCredential()

        XCTAssertEqual(credential.accessToken, accessToken)
        XCTAssertEqual(credential.accountID, "account-123")
        XCTAssertEqual(refreshCalls.value, 0)
    }

    func testExpiredAccessTokenTriggersRefreshAndPersist() async throws {
        let past = Date().addingTimeInterval(-60)
        let expiredAccess = makeJWT(expiration: past)
        let idToken = makeJWT(email: "user@example.com", plan: "prolite")
        let store = writeAuth(makeAuthJSON(accessToken: expiredAccess, idToken: idToken))
        let session = makeSession(store: store)

        let (credential, updated) = try await session.validCredential()

        XCTAssertEqual(credential.accessToken, "new-access")
        XCTAssertEqual(updated.tokens?.refreshToken, "new-refresh")

        // The store on disk now carries the rotated tokens, so the CLI and
        // Refinery share one login session.
        let reread = try store.loadChatGPTTokens()
        XCTAssertEqual(reread.tokens?.accessToken, "new-access")
        XCTAssertEqual(reread.tokens?.refreshToken, "new-refresh")
        XCTAssertEqual(reread.tokens?.idToken, "new-id")
        XCTAssertNotNil(reread.lastRefresh)
    }

    func testTokenWithinSkewWindowIsRefreshed() async throws {
        // 10 seconds left: inside the 30-second skew, treated as expired.
        let nearlyExpired = makeJWT(expiration: Date().addingTimeInterval(10))
        let store = writeAuth(makeAuthJSON(accessToken: nearlyExpired))
        let session = makeSession(store: store)

        let (credential, _) = try await session.validCredential()
        XCTAssertEqual(credential.accessToken, "new-access")
    }

    func testFailedRefreshSurfacesActionableErrorAndDoesNotTouchStore() async throws {
        let past = Date().addingTimeInterval(-60)
        let expiredAccess = makeJWT(expiration: past)
        let original = makeAuthJSON(accessToken: expiredAccess)
        let store = writeAuth(original)
        let session = makeSession(store: store) { _ in
            (
                Data("{}".utf8),
                HTTPURLResponse(
                    url: OAuthTokenRefresher.tokenEndpoint,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        do {
            _ = try await session.validCredential()
            XCTFail("expected refreshFailed")
        } catch let error as ChatGPTSession.SessionError {
            guard case .refreshFailed(let message) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(message.contains("codex login"), "message should point at codex login: \(message)")
        } catch {
            XCTFail("unexpected error \(error)")
        }

        // The store keeps the expired tokens: a failed exchange must not
        // destroy the CLI's session.
        XCTAssertEqual(try store.loadChatGPTTokens(), try JSONDecoder().decode(CodexAuthFile.self, from: original))
    }

    func testMissingRefreshTokenIsRejected() async throws {
        let past = Date().addingTimeInterval(-60)
        let expiredAccess = makeJWT(expiration: past)
        var payload = (try! JSONSerialization.jsonObject(with: makeAuthJSON(accessToken: expiredAccess))) as! [String: Any]
        var tokens = payload["tokens"] as! [String: Any]
        tokens.removeValue(forKey: "refresh_token")
        payload["tokens"] = tokens
        let store = writeAuth(try! JSONSerialization.data(withJSONObject: payload))
        let session = makeSession(store: store)

        do {
            _ = try await session.validCredential()
            XCTFail("expected missingTokens")
        } catch let error as CodexAuthStoreError {
            XCTAssertEqual(error, .missingTokens)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAccountSummaryReadsIdentityFromIdToken() throws {
        let future = Date().addingTimeInterval(3600)
        let idToken = makeJWT(expiration: future, email: "user@example.com", plan: "prolite")
        let store = writeAuth(makeAuthJSON(accessToken: makeJWT(), idToken: idToken))
        let session = makeSession(store: store)

        let summary = session.accountSummary()

        XCTAssertEqual(summary.email, "user@example.com")
        XCTAssertEqual(summary.planType, "prolite")
        XCTAssertNotNil(summary.lastRefresh)
        XCTAssertTrue(summary.signedIn)
    }

    func testAccountSummaryIsQuietWhenUnreadable() {
        let session = makeSession(store: writeAuth(Data("garbage".utf8)))
        let summary = session.accountSummary()
        XCTAssertFalse(summary.signedIn)
        XCTAssertNil(summary.email)
    }

    func testParseLastRefreshAcceptsFractionalAndPlainISO() {
        XCTAssertNotNil(ChatGPTSession.parseLastRefresh("2026-09-15T06:21:29.664762Z"))
        XCTAssertNotNil(ChatGPTSession.parseLastRefresh("2026-09-15T06:21:29Z"))
        XCTAssertNil(ChatGPTSession.parseLastRefresh(nil))
        XCTAssertNil(ChatGPTSession.parseLastRefresh("not a date"))
    }
}

// MARK: - SubscriptionAccountController (sign-out discipline)

@MainActor
final class SubscriptionAccountControllerTests: XCTestCase {
    /// Writes a signed-in auth fixture and builds the controller over it.
    private func makeController() -> (controller: SubscriptionAccountController, cleanup: () -> Void) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("refinery-tests-\(UUID().uuidString).json")
        let future = Date().addingTimeInterval(3600)
        let idToken = makeJWT(expiration: future, email: "user@example.com", plan: "prolite")
        try! makeAuthJSON(accessToken: makeJWT(expiration: future), idToken: idToken)
            .write(to: fileURL)
        let session = ChatGPTSession(store: CodexAuthStore(fileURL: fileURL))
        return (
            SubscriptionAccountController(session: session),
            { try? FileManager.default.removeItem(at: fileURL) }
        )
    }

    func testSignOutClearsTheReferenceButNotTheLoginOnDisk() {
        let (controller, cleanup) = makeController()
        defer { cleanup() }
        XCTAssertTrue(controller.isSignedIn)

        controller.signOut()

        XCTAssertFalse(controller.isSignedIn)
        XCTAssertTrue(controller.loginExistsOnDisk)
        XCTAssertNil(controller.account.email)

        controller.adoptExistingLogin()
        XCTAssertTrue(controller.isSignedIn)
        XCTAssertEqual(controller.account.email, "user@example.com")
    }

    func testCredentialIsBlockedAfterInAppSignOut() async {
        let (controller, cleanup) = makeController()
        defer { cleanup() }
        controller.signOut()

        do {
            _ = try await controller.credential()
            XCTFail("expected the sign-out gate")
        } catch let error as SubscriptionError {
            guard case .session(let message) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(message.contains("signed out"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

// MARK: - SubscriptionClient wire format

final class SubscriptionClientTests: XCTestCase {
    private let sseResponse = """
    data: {"type":"response.output_text.delta","delta":"Polished output"}

    data: {"type":"response.completed","response":{"id":"resp_1"}}

    """

    /// Captures the outbound request and replies with a canned SSE stream.
    private func makeRecordingTransport(
        status: Int = 200,
        captured: LockedRequestBox = LockedRequestBox()
    ) -> (transport: SubscriptionClient.Transport, box: LockedRequestBox) {
        let sse = sseResponse
        let transport: SubscriptionClient.Transport = { request in
            captured.set(request)
            let stream = Data(sse.utf8)
            let response = CachedHTTPResponse(
                status: status,
                url: request.url!,
                bytes: stream
            )
            return (stream, response)
        }
        return (transport, captured)
    }

    func testPolishSendsCodexHeadersAndBody() async throws {
        let (transport, box) = makeRecordingTransport()
        let client = SubscriptionClient(
            baseURL: URL(string: "https://chatgpt.com/backend-api")!,
            model: "gpt-5.6-luna",
            timeout: 5,
            transport: transport
        )

        let result = try await client.polish(
            "hej med dig",
            preset: .polish,
            credential: ChatGPTSession.Credential(accessToken: "sub-access", accountID: "acct-42")
        )
        XCTAssertEqual(result, "Polished output")

        let request = try XCTUnwrap(box.get())
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sub-access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "acct-42")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "responses=experimental")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "refinery")

        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        let instructions = try XCTUnwrap(body["instructions"] as? String)
        XCTAssertTrue(instructions.contains("polish"), "instructions should carry the preset prompt")
    }

    func testPolishSurfacesHTTPRejection() async throws {
        let (transport, _) = makeRecordingTransport(status: 401)
        let client = SubscriptionClient(
            baseURL: URL(string: "https://chatgpt.com/backend-api")!,
            model: "gpt-5.6-luna",
            timeout: 5,
            transport: transport
        )

        do {
            _ = try await client.polish(
                "text",
                preset: .polish,
                credential: ChatGPTSession.Credential(accessToken: "sub-access", accountID: "acct-42")
            )
            XCTFail("expected httpStatus")
        } catch let error as SubscriptionError {
            XCTAssertEqual(error, .httpStatus(401))
        }
    }

    func testRequestURLJoinsCodexResponses() {
        XCTAssertEqual(
            SubscriptionClient.requestURL(for: SubscriptionClient.productionBaseURL).absoluteString,
            "https://chatgpt.com/backend-api/codex/responses"
        )
        XCTAssertEqual(
            SubscriptionClient.requestURL(
                for: URL(string: "https://chatgpt.com/backend-api/")!
            ).absoluteString,
            "https://chatgpt.com/backend-api/codex/responses"
        )
    }

    func testBodyMatchesTheCodexResponsesWireFormat() throws {
        let body = SubscriptionClient.makeBody(
            model: "gpt-5.6-luna",
            instructions: "Be brief.",
            userText: "hej med dig"
        )
        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["instructions"] as? String, "Be brief.")
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[0]["text"] as? String, "hej med dig")
        let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "low")
        let text = try XCTUnwrap(json["text"] as? [String: String])
        XCTAssertEqual(text["verbosity"], "low")
    }

    func testParseSSEAssemblesOutputTextDeltas() throws {
        let sse = """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Hello "}

        data: {"type":"response.output_text.delta","delta":"  indented"}

        data: {"type":"response.completed","response":{"id":"resp_1"}}

        """
        let output = try SubscriptionClient.parseSSE(from: Data(sse.utf8))
        XCTAssertEqual(output, "Hello   indented")
    }

    func testParseSSEIgnoresReasoningAndNonDataLines() throws {
        let sse = """
        : comment stream
        event: response.reasoning_summary_text.delta
        data: {"type":"response.reasoning_summary_text.delta","delta":"thinking"}

        data: {"type":"response.output_text.delta","delta":"polished"}

        data: {"type":"response.completed","response":{}}

        """
        let output = try SubscriptionClient.parseSSE(from: Data(sse.utf8))
        XCTAssertEqual(output, "polished")
    }

    func testParseSSERejectsMissingCompletion() {
        let sse = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"
        XCTAssertThrowsError(try SubscriptionClient.parseSSE(from: Data(sse.utf8))) { error in
            XCTAssertEqual(error as? SubscriptionError, .incompleteCompletion)
        }
    }

    func testParseSSERejectsEmptyOutput() {
        let sse = "data: {\"type\":\"response.completed\",\"response\":{}}\n\n"
        XCTAssertThrowsError(try SubscriptionClient.parseSSE(from: Data(sse.utf8))) { error in
            XCTAssertEqual(error as? SubscriptionError, .emptyCompletion)
        }
    }

    func testParseSSERejectsIncompleteAndFailedResponses() {
        for terminal in ["response.incomplete", "response.failed", "error"] {
            let sse = "data: {\"type\":\"\(terminal)\"}\n\n"
            XCTAssertThrowsError(try SubscriptionClient.parseSSE(from: Data(sse.utf8)))
        }
    }
}

// MARK: - ProviderSelection + PolishService routing

final class ProviderSelectionTests: XCTestCase {
    func testDefaultProviderIsNone() {
        let settings = AppSettings(baseURL: "https://api.example.com/v1", model: "m")
        XCTAssertEqual(settings.provider, .none)
    }

    func testActiveProviderFollowsSelection() {
        var settings = AppSettings(baseURL: "https://api.example.com/v1", model: "m")
        settings.provider = .none
        XCTAssertEqual(PolishService(settings: settings).activeProvider, nil)

        settings.provider = .openAISubscription
        XCTAssertEqual(PolishService(settings: settings).activeProvider, .openAISubscription)

        settings.provider = .openAICompatibleEndpoint
        XCTAssertEqual(PolishService(settings: settings).activeProvider, .openAICompatibleEndpoint)

        // An endpoint provider with an unusable URL is inactive.
        settings.baseURL = "not a url"
        XCTAssertEqual(PolishService(settings: settings).activeProvider, nil)
    }

    func testSettingsDecodeCarriesTheProvider() throws {
        let suite = "RefineryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var settings = AppSettings(baseURL: "https://api.example.com/v1", model: "m")
        settings.provider = .openAISubscription
        settings.save(to: defaults)

        let loaded = try AppSettings.load(from: defaults)
        XCTAssertEqual(loaded.provider, .openAISubscription)
    }
}
