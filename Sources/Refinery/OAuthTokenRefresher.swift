import Foundation

private final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// The OAuth token exchange the codex CLI itself uses, so a refresh performed
/// by Refinery is indistinguishable from the CLI's own and both share one
/// login session persisted in `~/.codex/auth.json`.
///
/// Endpoint: POST https://auth.openai.com/oauth/token
/// Body (form-encoded): grant_type=refresh_token, refresh_token=<token>,
/// client_id=app_EMoamEEZ73f0CkXaXp7hrann (the codex CLI's public client id).
///
/// Tokens are never logged and never leave the machine except to this
/// OpenAI endpoint.
struct OAuthTokenRefresher: Sendable {
    static let tokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    /// The codex CLI's public OAuth client id.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    /// A successful refresh: new tokens plus their lifetime in seconds.
    struct RefreshedTokens: Equatable, Sendable {
        var accessToken: String
        var idToken: String?
        var refreshToken: String
        var expiresInSeconds: Int
    }

    enum RefreshError: LocalizedError, Equatable {
        /// The transport failed before an HTTP response arrived.
        case network(String)
        /// A non-2xx status came back. The body is deliberately not included:
        /// it may echo request fragments.
        case httpStatus(Int)
        /// A 2xx response whose body could not be decoded.
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .network:
                return "Could not reach OpenAI to refresh the ChatGPT login."
            case .httpStatus(let code):
                return "OpenAI rejected the ChatGPT login refresh (HTTP \(code)). Run `codex login` again."
            case .invalidResponse:
                return "OpenAI returned an unreadable refresh response."
            }
        }
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    let timeout: TimeInterval
    let transport: Transport

    init(timeout: TimeInterval = 30, transport: @escaping Transport = OAuthTokenRefresher.defaultTransport) {
        self.timeout = timeout
        self.transport = transport
    }

    static func defaultTransport(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(
            configuration: configuration,
            delegate: RedirectRejectingDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.synchronousData(request)
        guard let http = response as? HTTPURLResponse else {
            throw RefreshError.network("not an HTTP response")
        }
        return (data, http)
    }

    /// Performs the refresh-token exchange. The refresh token is single-use:
    /// the caller must persist the result (which rotates it) or not call this.
    func refresh(
        refreshToken: String,
        now: @escaping () -> Date = { Date() }
    ) async throws -> RefreshedTokens {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Refinery/1.0", forHTTPHeaderField: "User-Agent")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: Self.clientID),
        ]
        // Form-encode the body as the codex CLI does.
        var body = ""
        if let encoded = components.percentEncodedQuery {
            body = encoded
        }
        request.httpBody = Data(body.utf8)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as RefreshError {
            throw error
        } catch {
            throw RefreshError.network(error.localizedDescription)
        }

        guard (200...299).contains(response.statusCode) else {
            throw RefreshError.httpStatus(response.statusCode)
        }

        struct ResponseBody: Decodable {
            var accessToken: String?
            var idToken: String?
            var refreshToken: String?
            var expiresIn: Int?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case idToken = "id_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let accessToken = decoded.accessToken, !accessToken.isEmpty,
              let newRefreshToken = decoded.refreshToken, !newRefreshToken.isEmpty,
              let expiresIn = decoded.expiresIn, expiresIn > 0 else {
            throw RefreshError.invalidResponse
        }
        return RefreshedTokens(
            accessToken: accessToken,
            idToken: decoded.idToken,
            refreshToken: newRefreshToken,
            expiresInSeconds: expiresIn
        )
    }
}

private extension URLSession {
    /// `URLSession.data(for:)` without following redirects (the delegate
    /// above already rejects them; this keeps the response as-is).
    func synchronousData(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.data(for: request)
    }
}
