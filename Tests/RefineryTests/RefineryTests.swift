import XCTest
import AppKit
import Carbon.HIToolbox
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

@MainActor
final class HotkeyRecorderTests: XCTestCase {
    func testDefaultHotkeyComboIsAccepted() {
        let defaultModifiers = UInt32(cmdKey | optionKey)
        XCTAssertFalse(
            HotkeyRecorder.isReservedCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: defaultModifiers),
            "the documented default hotkey Opt+Cmd+P must be recordable"
        )
    }

    func testUniversalShortcutCombosAreRejected() {
        let combos: [(UInt32, String)] = [
            (UInt32(kVK_ANSI_C), "Cmd+C"),
            (UInt32(kVK_ANSI_V), "Cmd+V"),
            (UInt32(kVK_ANSI_X), "Cmd+X"),
            (UInt32(kVK_ANSI_Z), "Cmd+Z"),
            (UInt32(kVK_ANSI_A), "Cmd+A"),
            (UInt32(kVK_Space), "Cmd+Space"),
            (UInt32(kVK_Tab), "Cmd+Tab"),
        ]
        for (keyCode, name) in combos {
            XCTAssertTrue(
                HotkeyRecorder.isReservedCombo(keyCode: keyCode, modifiers: UInt32(cmdKey)),
                "\(name) must be rejected as a recorded hotkey"
            )
        }
    }

    func testNonCommandCombosPassThrough() {
        XCTAssertFalse(
            HotkeyRecorder.isReservedCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey))
        )
        XCTAssertFalse(
            HotkeyRecorder.isReservedCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey))
        )
    }

    func testDisplayStringForDefaultHotkey() {
        XCTAssertEqual(
            HotkeyRecorder.displayString(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey)),
            "⌥⌘P"
        )
    }

    func testFunctionKeysHaveLabels() {
        XCTAssertEqual(
            HotkeyRecorder.displayString(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey | optionKey)),
            "⌥⌘F5"
        )
        XCTAssertEqual(HotkeyRecorder.keyLabel(UInt32(kVK_F1)), "F1")
        XCTAssertEqual(HotkeyRecorder.keyLabel(UInt32(kVK_F12)), "F12")
        XCTAssertEqual(HotkeyRecorder.keyLabel(UInt32(kVK_F19)), "F19")
    }

    func testCarbonModifiersFromCGEventFlags() {
        XCTAssertEqual(
            HotkeyRecorder.carbonModifiers(from: [.maskCommand, .maskAlternate]),
            UInt32(cmdKey | optionKey)
        )
        XCTAssertEqual(
            HotkeyRecorder.carbonModifiers(from: [.maskShift, .maskControl]),
            UInt32(shiftKey | controlKey)
        )
        XCTAssertEqual(HotkeyRecorder.carbonModifiers(from: []), 0)
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

/// Drives a RecordingSession through real key events to verify capture,
/// cancel, teardown and modifier handling without a physical keyboard.
///
/// Each test builds its session directly via `makeSession`, so every
/// assertion runs regardless of whether the test host can create the HID
/// event tap; the tap-creation-failure branch of `start()` is covered
/// separately in `testStartInvokesCompletionWhenTapCannotBeCreated`.
@MainActor
final class RecordingSessionTests: XCTestCase {
    private func keyEvent(keyCode: CGKeyCode, flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        event.flags = flags
        return event
    }

    /// A session installed as current without running `start()`, so the
    /// tests never depend on CGEvent.tapCreate succeeding in the test host.
    private func makeSession() -> (session: RecordingSession, box: Box<(UInt32?, UInt32?, String)?>) {
        let box = Box<(UInt32?, UInt32?, String)?>(nil)
        let session = RecordingSession { keyCode, modifiers, reason in
            box.value = (keyCode, modifiers, reason)
        }
        HotkeyRecorder.currentSession = session
        return (session, box)
    }

    func testStartInvokesCompletionWhenTapCannotBeCreated() {
        // The tap callback path needs Accessibility; start() handles the
        // failure branch deterministically by completing with nil.
        let box = Box<(UInt32?, UInt32?, String)?>(nil)
        HotkeyRecorder.start { keyCode, modifiers, reason in
            box.value = (keyCode, modifiers, reason)
        }
        if HotkeyRecorder.currentSession == nil {
            // Tap creation failed in this environment: start() must have
            // completed synchronously with the permission failure.
            XCTAssertNil(box.value?.0)
            XCTAssertEqual(box.value?.2, "Could not listen for keyboard events; check the Accessibility permission.")
        } else {
            // Tap creation succeeded in this environment; the session stays
            // current until a combination is captured.
            HotkeyRecorder.currentSession?.handle(keyEvent(keyCode: CGKeyCode(kVK_ANSI_P), flags: [.maskCommand, .maskAlternate]))
            XCTAssertEqual(box.value?.0, UInt32(kVK_ANSI_P))
            XCTAssertEqual(box.value?.1, UInt32(cmdKey | optionKey))
            XCTAssertNil(HotkeyRecorder.currentSession)
        }
        XCTAssertNotNil(box.value)
    }

    func testHandleCapturesCommandOptionCombo() {
        let (session, box) = makeSession()
        session.handle(keyEvent(keyCode: CGKeyCode(kVK_ANSI_J), flags: [.maskCommand, .maskAlternate]))
        XCTAssertEqual(box.value?.0, UInt32(kVK_ANSI_J))
        XCTAssertEqual(box.value?.1, UInt32(cmdKey | optionKey))
        XCTAssertEqual(box.value?.2, "⌥⌘J")
        XCTAssertNil(HotkeyRecorder.currentSession)
    }

    func testHandleEscapeCancelsWithoutRebinding() {
        let (session, box) = makeSession()
        session.handle(keyEvent(keyCode: CGKeyCode(kVK_Escape), flags: [.maskCommand]))
        XCTAssertNil(box.value?.0)
        XCTAssertEqual(box.value?.2, "Cancelled.")
        XCTAssertNil(HotkeyRecorder.currentSession)
    }

    func testHandleReservedComboIsRejected() {
        let (session, box) = makeSession()
        session.handle(keyEvent(keyCode: CGKeyCode(kVK_ANSI_C), flags: [.maskCommand]))
        XCTAssertNil(box.value?.0)
        XCTAssertEqual(box.value?.2, "That combination conflicts with a common system shortcut.")
        XCTAssertNil(HotkeyRecorder.currentSession)
    }

    func testHandlePlainKeyWithoutRequiredModifierIsIgnored() {
        let (session, box) = makeSession()
        session.handle(keyEvent(keyCode: CGKeyCode(kVK_ANSI_P)))
        XCTAssertNil(box.value)
        XCTAssertTrue(HotkeyRecorder.currentSession === session)
        session.invalidate()
    }

    func testHandleBareModifierPressIsIgnored() {
        let (session, box) = makeSession()
        session.handle(keyEvent(keyCode: CGKeyCode(kVK_Command), flags: [.maskCommand]))
        XCTAssertNil(box.value)
        XCTAssertTrue(HotkeyRecorder.currentSession === session)
        session.handle(keyEvent(keyCode: CGKeyCode(kVK_RightOption), flags: [.maskCommand, .maskAlternate]))
        XCTAssertNil(box.value)
        XCTAssertTrue(HotkeyRecorder.currentSession === session)
        session.invalidate()
    }

    func testMenuCloseEndsSessionAndClearsCurrentSession() {
        let (session, box) = makeSession()
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
        XCTAssertEqual(box.value?.2, "Cancelled.")
        XCTAssertNil(HotkeyRecorder.currentSession)
    }

    func testInvalidatedSessionDeliversNoCompletion() {
        let (session, box) = makeSession()
        session.invalidate()
        XCTAssertNil(box.value)
        XCTAssertNil(HotkeyRecorder.currentSession)

        // A late event after teardown must not resurrect the session.
        session.handle(keyEvent(keyCode: CGKeyCode(kVK_ANSI_P), flags: [.maskCommand, .maskAlternate]))
        XCTAssertNil(box.value)
    }

    func testStartReplacesPreviousSessionWithoutCompletingIt() {
        let (first, firstBox) = makeSession()

        let secondBox = Box<(UInt32?, UInt32?, String)?>(nil)
        HotkeyRecorder.start { keyCode, modifiers, reason in
            secondBox.value = (keyCode, modifiers, reason)
        }
        let second = HotkeyRecorder.currentSession

        // The previous session is invalidated, never completed.
        XCTAssertNil(firstBox.value)
        XCTAssertFalse(HotkeyRecorder.currentSession === first)

        if let second {
            // Tap creation succeeded: the new session is current and captures.
            XCTAssertFalse(second === first)
            second.handle(keyEvent(keyCode: CGKeyCode(kVK_ANSI_P), flags: [.maskCommand, .maskAlternate]))
            XCTAssertEqual(secondBox.value?.0, UInt32(kVK_ANSI_P))
            XCTAssertNil(HotkeyRecorder.currentSession)
        } else {
            // Tap creation failed: the new session completed with nil.
            XCTAssertNotNil(secondBox.value)
            XCTAssertNil(secondBox.value?.0)
        }
    }
}

/// A tiny reference box for capturing completion results from tests.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Test double that records the URLRequest and returns a canned response.
private final class RequestRecorder: @unchecked Sendable {    private var _lastRequest: URLRequest?
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
