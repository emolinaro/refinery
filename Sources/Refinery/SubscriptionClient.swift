import Foundation

/// Errors surfaced by `SubscriptionClient`.
enum SubscriptionError: LocalizedError, Equatable {
    /// The ChatGPT session could not be established or refreshed.
    case session(String)
    /// The request could not be built.
    case invalidRequest
    /// The request timed out or the connection failed.
    case network(String)
    /// A non-2xx HTTP status came back.
    case httpStatus(Int)
    /// The endpoint response exceeded Refinery's memory limit.
    case responseTooLarge
    /// The SSE stream was malformed.
    case invalidResponse
    /// The stream completed without any output text.
    case emptyCompletion
    /// The stream ended before the response completed.
    case incompleteCompletion

    public var errorDescription: String? {
        switch self {
        case .session(let message):
            return message
        case .invalidRequest:
            return "The request to OpenAI could not be built."
        case .network(let message):
            return "Could not reach OpenAI: \(message)"
        case .httpStatus(let code):
            return "OpenAI returned HTTP \(code)."
        case .responseTooLarge:
            return "The OpenAI response exceeded the 4 MB limit."
        case .invalidResponse:
            return "OpenAI returned a response Refinery could not parse."
        case .emptyCompletion:
            return "OpenAI returned an empty result."
        case .incompleteCompletion:
            return "OpenAI returned an incomplete result."
        }
    }
}

/// Client for the ChatGPT backend-api surface the codex CLI itself uses:
/// `POST https://chatgpt.com/backend-api/codex/responses` with the account's
/// bearer tokens, streaming SSE.
///
/// The chat/completions-shaped presets map onto the Responses wire format:
/// system prompt -> `instructions`, user text -> one `input` message. The
/// model is a subscription-eligible member of the codex CLI's gpt-5.x family
/// (gpt-5.6-luna, the cheapest subscription-eligible tier).
///
/// Tokens are passed in per request and are never logged, stored by this
/// type, or included in error descriptions.
struct SubscriptionClient {
    static let productionBaseURL = URL(string: "https://chatgpt.com/backend-api")!
    /// The subscription-eligible model the codex CLI's config uses for this
    /// account (see config.toml `model = "gpt-5.6-sol"`); Refinery uses the
    /// cheaper subscription-eligible gpt-5.6 family member for polish work.
    static let defaultModel = "gpt-5.6-luna"

    static let maximumResponseBytes = 4 * 1024 * 1024

    /// Originator header value, mirroring the codex CLI's convention.
    private static let originator = "refinery"

    let baseURL: URL
    let model: String
    let timeout: TimeInterval
    let transport: Transport

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(
        baseURL: URL = SubscriptionClient.productionBaseURL,
        model: String = SubscriptionClient.defaultModel,
        timeout: TimeInterval = 60,
        transport: @escaping Transport = { request in
            try await SubscriptionClient.defaultTransport(request, timeout: 60)
        }
    ) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.transport = transport
    }

    static func requestURL(for baseURL: URL) -> URL {
        var url = baseURL
        // Normalize trailing slash before appending path components.
        if url.path.hasSuffix("/") {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("codex/responses")
    }

    /// Request body for the Responses API, mirroring what the codex CLI sends:
    /// stream=true, store=false, plain text verbosity, and a minimal
    /// reasoning effort - polish work needs none.
    struct RequestBody: Codable {
        struct InputMessage: Codable {
            struct ContentPart: Codable {
                var type: String
                var text: String
            }
            var role: String
            var content: [ContentPart]
        }

        struct Reasoning: Codable {
            var effort: String
            var summary: String
        }

        var model: String
        var store: Bool
        var stream: Bool
        var instructions: String
        var input: [InputMessage]
        var reasoning: Reasoning?
        var text: [String: String]
    }

    static func makeBody(
        model: String,
        instructions: String,
        userText: String
    ) -> RequestBody {
        RequestBody(
            model: model,
            store: false,
            stream: true,
            instructions: instructions,
            input: [
                RequestBody.InputMessage(
                    role: "user",
                    content: [RequestBody.InputMessage.ContentPart(
                        type: "input_text",
                        text: userText
                    )]
                )
            ],
            reasoning: RequestBody.Reasoning(effort: "low", summary: "auto"),
            text: ["verbosity": "low"]
        )
    }

    /// Runs a polish request against the ChatGPT backend-api.
    /// - Parameters:
    ///   - selectedText: the text captured from the user's selection.
    ///   - preset: the chosen preset.
    ///   - customPrompt: the typed instruction, used only by `.customOneOff`.
    ///   - credential: the ChatGPT bearer credential. Never logged, never
    ///     persisted here.
    /// - Returns: the polished text assembled from the streamed deltas.
    func polish(
        _ selectedText: String,
        preset: Preset,
        customPrompt: String? = nil,
        credential: ChatGPTSession.Credential
    ) async throws -> String {
        let instructions: String
        do {
            instructions = try PresetPromptBuilder.systemPrompt(for: preset, customPrompt: customPrompt)
        } catch {
            throw error
        }

        let accessToken = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw SubscriptionError.session(CodexAuthStoreError.missingTokens.localizedDescription)
        }

        let url = Self.requestURL(for: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credential.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue(Self.originator, forHTTPHeaderField: "originator")
        request.setValue("Refinery/1.0", forHTTPHeaderField: "User-Agent")

        let body = Self.makeBody(model: model, instructions: instructions, userText: selectedText)
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw SubscriptionError.invalidRequest
        }

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport(request)
        } catch let error as SubscriptionError {
            throw error
        } catch {
            throw SubscriptionError.network(error.localizedDescription)
        }

        guard (200...299).contains(response.statusCode) else {
            throw SubscriptionError.httpStatus(response.statusCode)
        }

        return try Self.parseSSE(from: data)
    }

    static func defaultTransport(
        _ request: URLRequest,
        timeout: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SubscriptionError.network("not an HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            _ = try? await bytes.lines.reduce(into: Data()) { _, _ in }
            throw SubscriptionError.httpStatus(http.statusCode)
        }
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            throw SubscriptionError.responseTooLarge
        }
        var accumulator = ResponseAccumulator(limit: maximumResponseBytes)
        for try await byte in bytes {
            try accumulator.append(byte)
        }
        return (accumulator.data, http)
    }

    /// Parses the SSE stream: accumulates `response.output_text.delta`
    /// events until `response.completed`. Preserves the model's own
    /// whitespace in the assembled text.
    static func parseSSE(from data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SubscriptionError.invalidResponse
        }
        var output = ""
        var sawCompleted = false
        var sawDelta = false

        for rawEvent in text.components(separatedBy: "\n\n") {
            // Each SSE event is one or more `data:` lines; others (comments,
            // ids) are ignored per the SSE spec.
            let dataLines = rawEvent
                .components(separatedBy: "\n")
                .filter { $0.hasPrefix("data:") }
                .map { String($0.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces) }
            guard !dataLines.isEmpty else { continue }
            let payload = dataLines.joined(separator: "\n")
            if payload == "[DONE]" { break }
            guard let payloadData = payload.data(using: .utf8) else { continue }

            struct StreamEvent: Decodable {
                var type: String?
                var delta: String?

                enum CodingKeys: String, CodingKey {
                    case type
                    case delta
                }
            }
            guard let event = try? JSONDecoder().decode(StreamEvent.self, from: payloadData) else {
                continue
            }
            switch event.type {
            case "response.output_text.delta":
                output += event.delta ?? ""
                sawDelta = true
            case "response.completed":
                sawCompleted = true
            case "response.incomplete", "response.failed":
                throw SubscriptionError.incompleteCompletion
            case "error":
                throw SubscriptionError.invalidResponse
            default:
                break
            }
        }

        guard sawCompleted else { throw SubscriptionError.incompleteCompletion }
        guard sawDelta, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SubscriptionError.emptyCompletion
        }
        return output
    }
}
