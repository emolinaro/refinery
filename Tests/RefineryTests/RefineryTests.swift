import XCTest
@testable import Refinery

final class PresetPromptBuilderTests: XCTestCase {
    func testExactlySixPresets() {
        XCTAssertEqual(Preset.allCases.count, 6)
        XCTAssertEqual(
            Set(Preset.allCases),
            [.polish, .concise, .formal, .friendlyEmail, .languageAware, .customOneOff]
        )
    }

    func testMessagesShape() {
        let messages = PresetPromptBuilder.messages(for: "hello", preset: .polish)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], "hello")
    }

    func testCustomPromptOnlyUsedByCustomPreset() {
        let messages = PresetPromptBuilder.messages(
            for: "some text",
            preset: .polish,
            customPrompt: "IGNORE"
        )
        XCTAssertFalse(messages[0]["content"]?.contains("IGNORE") ?? true)

        let customMessages = PresetPromptBuilder.messages(
            for: "some text",
            preset: .customOneOff,
            customPrompt: "Make it a haiku"
        )
        XCTAssertTrue(customMessages[0]["content"]?.contains("Make it a haiku") ?? false)
    }

    func testEmptyCustomPromptFallsBackToPolish() {
        let prompt = PresetPromptBuilder.systemPrompt(for: .customOneOff, customPrompt: "   ")
        XCTAssertTrue(prompt.contains("Polish the text."))
    }

    func testSystemPromptsMentionReturnOnlyText() {
        for preset in Preset.allCases {
            let prompt = PresetPromptBuilder.systemPrompt(for: preset, customPrompt: "x")
            XCTAssertTrue(
                prompt.contains("ONLY"),
                "preset \(preset) should instruct the model to return only text"
            )
        }
    }

    func testLanguageAwarePromptNeverTranslates() {
        let prompt = PresetPromptBuilder.systemPrompt(for: .languageAware)
        XCTAssertTrue(prompt.contains("Danish"))
        XCTAssertTrue(prompt.contains("English"))
        XCTAssertTrue(prompt.contains("Never translate"))
    }
}

final class LanguageDetectorTests: XCTestCase {
    func testDanishSentence() {
        let text = "Jeg har en kat og den er meget fin, den kan lide at sove."
        XCTAssertEqual(LanguageDetector.detect(text), .danish)
    }

    func testEnglishSentence() {
        let text = "I have a cat and she is very nice, she likes to sleep all day."
        XCTAssertEqual(LanguageDetector.detect(text), .english)
    }

    func testDanishMarkerCharacters() {
        XCTAssertEqual(LanguageDetector.detect("Smørrebrød med øl på åen"), .danish)
    }

    func testDanishWithOneMarkerAndDanishWords() {
        let text = "Hej med dig, jeg håber at du har det godt og at vi snakkes ved."
        XCTAssertEqual(LanguageDetector.detect(text), .danish)
    }

    func testEnglishWithSingleFalseMarker() {
        // One stray 'å' should not flip clearly-English text.
        let text = "The manager will årrange the meeting and send the notes."
        XCTAssertEqual(LanguageDetector.detect(text), .english)
    }

    func testEmptyTextDefaultsToEnglish() {
        XCTAssertEqual(LanguageDetector.detect(""), .english)
    }

    func testNeutralShortTextDefaultsToEnglish() {
        XCTAssertEqual(LanguageDetector.detect("OK"), .english)
    }
}

final class EndpointClientTests: XCTestCase {
    private func makeClient(base: String = "https://api.example.com/v1") -> EndpointClient {
        EndpointClient(
            baseURL: URL(string: base)!,
            model: "test-model",
            timeout: 5
        )
    }

    func testPolishSendsStandardChatCompletionRequest() async throws {
        let recorder = RequestRecorder()
        let client = EndpointClient(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            timeout: 5,
            transport: .send(recorder.send)
        )

        let result = try await client.polish(
            "hej med dig",
            preset: .polish,
            apiKey: "dummy-key"
        )
        XCTAssertEqual(result, "Polished output")

        let request = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dummy-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "test-model")
        let messages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1]["content"] as? String, "hej med dig")
    }

    func testWhitespaceOnlyAPIKeyFails() async {
        let client = makeClient()
        do {
            _ = try await client.polish("text", preset: .polish, apiKey: "   ")
            XCTFail("expected missingAPIKey")
        } catch let error as EndpointError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("unexpected error type \(error)")
        }
    }

    func testHTTPErrorSurfacesStatus() async {
        let failing = EndpointClient.Transport.send { _ in
            (Data("nope".utf8), HTTPURLResponse(
                url: URL(string: "https://api.example.com/v1/chat/completions")!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!)
        }
        let client = EndpointClient(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            timeout: 5,
            transport: failing
        )
        do {
            _ = try await client.polish("text", preset: .polish, apiKey: "dummy")
            XCTFail("expected httpStatus")
        } catch let error as EndpointError {
            guard case .httpStatus(let code, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("unexpected error type \(error)")
        }
    }

    func testEmptyCompletionSurfacesError() async {
        let empty = EndpointClient.Transport.send { _ in
            (Data(#"{"choices":[]}"#.utf8), HTTPURLResponse(
                url: URL(string: "https://api.example.com/v1/chat/completions")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!)
        }
        let client = EndpointClient(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            timeout: 5,
            transport: empty
        )
        do {
            _ = try await client.polish("text", preset: .polish, apiKey: "dummy")
            XCTFail("expected emptyCompletion")
        } catch let error as EndpointError {
            XCTAssertEqual(error, .emptyCompletion)
        } catch {
            XCTFail("unexpected error type \(error)")
        }
    }
}

/// Test double that records the URLRequest and returns a canned response.
private final class RequestRecorder: @unchecked Sendable {
    private var _lastRequest: URLRequest?
    private let semaphore = DispatchSemaphore(value: 1)
    private(set) var lastRequest: URLRequest? {
        get {
            semaphore.wait()
            defer { semaphore.signal() }
            return _lastRequest
        }
        set {
            semaphore.wait()
            defer { semaphore.signal() }
            _lastRequest = newValue
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let json = """
        {"choices":[{"message":{"role":"assistant","content":"Polished output"}}]}
        """
        return (
            Data(json.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}
