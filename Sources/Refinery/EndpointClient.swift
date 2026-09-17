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

/// Errors surfaced by `EndpointClient`.
public enum EndpointError: LocalizedError, Equatable {
    /// The base URL is missing or malformed (e.g. not HTTP(S)).
    case invalidBaseURL
    /// The API key is missing from the Keychain.
    case missingAPIKey
    /// The request could not be built.
    case invalidRequest
    /// The request timed out or the connection failed.
    case network(String)
    /// A non-2xx HTTP status came back.
    case httpStatus(Int)
    /// The endpoint response exceeded Refinery's memory limit.
    case responseTooLarge
    /// The response body was not decodable as a chat-completions response.
    case invalidResponse
    /// The response carried no choices or an empty message.
    case emptyCompletion
    case incompleteCompletion(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The endpoint must use HTTPS, except for localhost development endpoints."
        case .missingAPIKey:
            return "No API key is saved. Add one in Refinery settings."
        case .invalidRequest:
            return "The request to the endpoint could not be built."
        case .network(let message):
            return "Could not reach the endpoint: \(message)"
        case .httpStatus(let code):
            return "The endpoint returned HTTP \(code)."
        case .responseTooLarge:
            return "The endpoint response exceeded the 4 MB limit."
        case .invalidResponse:
            return "The endpoint returned a response Refinery could not parse."
        case .emptyCompletion:
            return "The endpoint returned an empty result."
        case .incompleteCompletion(let reason):
            return "The endpoint returned an incomplete result (\(reason))."
        }
    }
}

/// A minimal, standard OpenAI chat-completions client.
///
/// Speaks POST {baseURL}/chat/completions with `Authorization: Bearer <key>`.
/// The API key is passed in per request and is never logged, stored on disk or
/// included in error descriptions.
public struct EndpointClient {
    static let maximumResponseBytes = 4 * 1024 * 1024

    public var baseURL: URL
    public var model: String
    public var timeout: TimeInterval = 60

    private struct RequestBody: Codable {
        var model: String
        var messages: [[String: String]]
        var temperature: Double = 0.3
    }

    private struct ResponseBody: Codable {
        struct Choice: Codable {
            struct Message: Codable {
                var content: String?
            }
            var message: Message?
            var finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        var choices: [Choice]?
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    var transport: Transport = { request in
        let session = URLSession(
            configuration: .ephemeral,
            delegate: RedirectRejectingDelegate(),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EndpointError.network("not an HTTP response")
        }
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            throw EndpointError.responseTooLarge
        }
        var accumulator = ResponseAccumulator(limit: maximumResponseBytes)
        for try await byte in bytes {
            try accumulator.append(byte)
        }
        return (accumulator.data, http)
    }

    public init(baseURL: URL, model: String, timeout: TimeInterval = 60) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
    }

    init(baseURL: URL, model: String, timeout: TimeInterval = 60, transport: @escaping Transport) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.transport = transport
    }

    static func isAllowedBaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }
        if scheme == "https" { return true }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    /// Runs a polish request against the configured endpoint.
    /// - Parameters:
    ///   - selectedText: the text captured from the user's selection.
    ///   - preset: the chosen preset.
    ///   - customPrompt: the typed instruction, used only by `.customOneOff`.
    ///   - apiKey: the bearer token. Never logged, never persisted here.
    /// - Returns: the polished text from the first choice.
    public func polish(
        _ selectedText: String,
        preset: Preset,
        customPrompt: String? = nil,
        apiKey: String
    ) async throws -> String {
        guard Self.isAllowedBaseURL(baseURL) else { throw EndpointError.invalidBaseURL }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw EndpointError.missingAPIKey }

        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Refinery/1.0", forHTTPHeaderField: "User-Agent")

        let body = RequestBody(
            model: model,
            messages: try PresetPromptBuilder.messages(
                for: selectedText,
                preset: preset,
                customPrompt: customPrompt
            )
        )
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw EndpointError.invalidRequest
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as EndpointError {
            throw error
        } catch {
            throw EndpointError.network(error.localizedDescription)
        }

        guard (200...299).contains(response.statusCode) else {
            throw EndpointError.httpStatus(response.statusCode)
        }

        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw EndpointError.invalidResponse
        }

        guard let choice = decoded.choices?.first else {
            throw EndpointError.emptyCompletion
        }
        if let reason = choice.finishReason, ["length", "content_filter"].contains(reason) {
            throw EndpointError.incompleteCompletion(reason)
        }
        guard let content = choice.message?.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EndpointError.emptyCompletion
        }
        return content
    }
}

struct ResponseAccumulator {
    let limit: Int
    private(set) var data = Data()

    mutating func append(_ byte: UInt8) throws {
        guard data.count < limit else { throw EndpointError.responseTooLarge }
        data.append(byte)
    }
}
