import Foundation

/// Errors surfaced by `EndpointClient`.
enum EndpointError: LocalizedError, Equatable {
    /// The base URL is missing or malformed (e.g. not HTTP(S)).
    case invalidBaseURL
    /// The API key is missing from the Keychain.
    case missingAPIKey
    /// The request could not be built.
    case invalidRequest
    /// The request timed out or the connection failed.
    case network(String)
    /// A non-2xx HTTP status came back.
    case httpStatus(Int, String)
    /// The response body was not decodable as a chat-completions response.
    case invalidResponse
    /// The response carried no choices or an empty message.
    case emptyCompletion

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The endpoint base URL is missing or not a valid http(s) URL."
        case .missingAPIKey:
            return "No API key is saved. Add one in Refinery settings."
        case .invalidRequest:
            return "The request to the endpoint could not be built."
        case .network(let message):
            return "Could not reach the endpoint: \(message)"
        case .httpStatus(let code, let body):
            let trimmed = body.isEmpty ? "no body" : String(body.prefix(300))
            return "The endpoint returned HTTP \(code): \(trimmed)"
        case .invalidResponse:
            return "The endpoint returned a response Refinery could not parse."
        case .emptyCompletion:
            return "The endpoint returned an empty result."
        }
    }
}

/// A minimal, standard OpenAI chat-completions client.
///
/// Speaks POST {baseURL}/chat/completions with `Authorization: Bearer <key>`.
/// The API key is passed in per request and is never logged, stored on disk or
/// included in error descriptions.
struct EndpointClient {
    var baseURL: URL
    var model: String
    var timeout: TimeInterval = 60

    private struct RequestBody: Codable {
        var model: String
        var messages: [[String: String]]
        var temperature: Double = 0.3
    }

    private struct ResponseBody: Codable {
        struct Choice: Codable {
            struct Message: Codable {
                var role: String?
                var content: String?
            }
            var message: Message?
        }
        var choices: [Choice]?
    }

    enum Transport {
        case send((URLRequest) async throws -> (Data, HTTPURLResponse))
    }

    var transport: Transport = .send { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EndpointError.network("not an HTTP response")
        }
        return (data, http)
    }

    /// Runs a polish request against the configured endpoint.
    /// - Parameters:
    ///   - selectedText: the text captured from the user's selection.
    ///   - preset: the chosen preset.
    ///   - customPrompt: the typed instruction, used only by `.customOneOff`.
    ///   - apiKey: the bearer token. Never logged, never persisted here.
    /// - Returns: the polished text from the first choice.
    func polish(
        _ selectedText: String,
        preset: Preset,
        customPrompt: String? = nil,
        apiKey: String
    ) async throws -> String {
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
            messages: PresetPromptBuilder.messages(
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

        let (data, response): (Data, HTTPURLResponse)
        switch transport {
        case .send(let send):
            do {
                (data, response) = try await send(request)
            } catch {
                throw EndpointError.network(error.localizedDescription)
            }
        }

        guard (200...299).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw EndpointError.httpStatus(response.statusCode, body)
        }

        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw EndpointError.invalidResponse
        }

        guard let content = decoded.choices?.first?.message?.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EndpointError.emptyCompletion
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
