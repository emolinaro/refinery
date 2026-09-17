import XCTest
import AppKit
import Carbon.HIToolbox
import Security
@testable import Refinery

final class PresetPromptBuilderTests: XCTestCase {
    func testPresetCases() {
        XCTAssertEqual(
            Set(Preset.allCases),
            [.polish, .concise, .formal, .friendlyEmail, .languageAware, .customOneOff]
        )
    }

    func testMessagesShape() throws {
        let messages = try PresetPromptBuilder.messages(for: "hello", preset: .polish)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], "hello")
    }

    func testCustomPromptOnlyUsedByCustomPreset() throws {
        let messages = try PresetPromptBuilder.messages(
            for: "some text",
            preset: .polish,
            customPrompt: "IGNORE"
        )
        XCTAssertFalse(messages[0]["content"]?.contains("IGNORE") ?? true)

        let customMessages = try PresetPromptBuilder.messages(
            for: "some text",
            preset: .customOneOff,
            customPrompt: "Make it a haiku"
        )
        XCTAssertTrue(customMessages[0]["content"]?.contains("Make it a haiku") ?? false)
    }

    func testEmptyCustomPromptFails() {
        XCTAssertThrowsError(try PresetPromptBuilder.systemPrompt(for: .customOneOff, customPrompt: "   ")) {
            XCTAssertEqual($0 as? PresetPromptError, .missingCustomPrompt)
        }
    }

    func testSystemPromptsMentionReturnOnlyText() throws {
        for preset in Preset.allCases {
            let prompt = try PresetPromptBuilder.systemPrompt(for: preset, customPrompt: "x")
            XCTAssertTrue(
                prompt.contains("ONLY"),
                "preset \(preset) should instruct the model to return only text"
            )
        }
    }

    func testLanguageAwarePromptNeverTranslates() throws {
        let prompt = try PresetPromptBuilder.systemPrompt(for: .languageAware)
        XCTAssertTrue(prompt.contains("Danish"))
        XCTAssertTrue(prompt.contains("English"))
        XCTAssertTrue(prompt.contains("Never translate"))
    }
}

@MainActor
final class HotkeyCenterTests: XCTestCase {
    func testSuppressedEventStaysSuppressedAfterResume() async {
        let center = HotkeyCenter()
        var triggerCount = 0
        center.onTrigger = { triggerCount += 1 }
        center.suspend()

        center.handleMatchedHotkeyEvent()
        center.resume()
        await drainMainQueue()

        XCTAssertEqual(triggerCount, 0)
    }

    func testUnsuppressedEventDispatchesTrigger() async {
        let center = HotkeyCenter()
        var triggerCount = 0
        center.onTrigger = { triggerCount += 1 }

        center.handleMatchedHotkeyEvent()
        await drainMainQueue()

        XCTAssertEqual(triggerCount, 1)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
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
            transport: recorder.send
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

    func testRemoteHTTPBaseURLIsRejectedBeforeSending() async {
        let recorder = RequestRecorder()
        let client = EndpointClient(
            baseURL: URL(string: "http://api.example.com/v1")!,
            model: "test-model",
            transport: recorder.send
        )
        do {
            _ = try await client.polish("text", preset: .polish, apiKey: "dummy")
            XCTFail("expected invalidBaseURL")
        } catch let error as EndpointError {
            XCTAssertEqual(error, .invalidBaseURL)
        } catch {
            XCTFail("unexpected error type \(error)")
        }
        XCTAssertNil(recorder.lastRequest)
    }

    func testLoopbackHTTPBaseURLsAreAllowed() {
        for base in ["http://localhost:8080/v1", "http://127.0.0.1/v1", "http://[::1]/v1"] {
            XCTAssertTrue(EndpointClient.isAllowedBaseURL(URL(string: base)!))
        }
    }

    func testPolishPreservesCompletionWhitespace() async throws {
        let response: EndpointClient.Transport = { request in
            let data = Data(#"{"choices":[{"message":{"content":"  indented\n"}}]}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let client = EndpointClient(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            transport: response
        )
        let result = try await client.polish("text", preset: .polish, apiKey: "dummy")
        XCTAssertEqual(result, "  indented\n")
    }

    func testEmptyCustomPromptFailsBeforeSending() async {
        let recorder = RequestRecorder()
        let client = EndpointClient(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            transport: recorder.send
        )
        do {
            _ = try await client.polish("text", preset: .customOneOff, customPrompt: " ", apiKey: "dummy")
            XCTFail("expected missingCustomPrompt")
        } catch let error as PresetPromptError {
            XCTAssertEqual(error, .missingCustomPrompt)
        } catch {
            XCTFail("unexpected error type \(error)")
        }
        XCTAssertNil(recorder.lastRequest)
    }

    func testHTTPErrorSurfacesStatus() async {
        let failing: EndpointClient.Transport = { _ in
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
            guard case .httpStatus(let code) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(code, 500)
            XCTAssertEqual(error.localizedDescription, "The endpoint returned HTTP 500.")
            XCTAssertFalse(error.localizedDescription.contains("nope"))
        } catch {
            XCTFail("unexpected error type \(error)")
        }
    }

    func testEmptyCompletionSurfacesError() async {
        let empty: EndpointClient.Transport = { _ in
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

    func testIncompleteCompletionSurfacesError() async {
        for reason in ["length", "content_filter", "tool_calls", "function_call"] {
            let response: EndpointClient.Transport = { request in
                let data = Data("{\"choices\":[{\"message\":{\"content\":\"Partial\"},\"finish_reason\":\"\(reason)\"}]}".utf8)
                return (data, HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!)
            }
            let client = EndpointClient(
                baseURL: URL(string: "https://api.example.com/v1")!,
                model: "test-model",
                transport: response
            )

            do {
                _ = try await client.polish("text", preset: .polish, apiKey: "dummy")
                XCTFail("expected incompleteCompletion")
            } catch let error as EndpointError {
                XCTAssertEqual(error, .incompleteCompletion)
                XCTAssertEqual(error.localizedDescription, "The endpoint returned an incomplete result.")
                XCTAssertFalse(error.localizedDescription.contains(reason))
            } catch {
                XCTFail("unexpected error type \(error)")
            }
        }
    }

    func testResponseAccumulatorRejectsDataBeyondLimit() throws {
        var accumulator = ResponseAccumulator(limit: 2)
        try accumulator.append(1)
        try accumulator.append(2)
        XCTAssertThrowsError(try accumulator.append(3)) {
            XCTAssertEqual($0 as? EndpointError, .responseTooLarge)
        }
        XCTAssertEqual(accumulator.data, Data([1, 2]))
    }

    func testResponseTooLargeErrorIsNotCollapsedIntoNetworkError() async {
        let client = EndpointClient(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            transport: { _ in throw EndpointError.responseTooLarge }
        )

        do {
            _ = try await client.polish("text", preset: .polish, apiKey: "dummy")
            XCTFail("expected responseTooLarge")
        } catch let error as EndpointError {
            XCTAssertEqual(error, .responseTooLarge)
        } catch {
            XCTFail("unexpected error type \(error)")
        }
    }
}

@MainActor
final class CustomPromptPanelTests: XCTestCase {
    func testNormalizedPromptRejectsBlankInput() {
        XCTAssertNil(CustomPromptPanel.normalizedPrompt(" \n\t "))
    }

    func testNormalizedPromptTrimsInput() {
        XCTAssertEqual(CustomPromptPanel.normalizedPrompt("  Make it direct. \n"), "Make it direct.")
    }
}

final class KeychainStoreTests: XCTestCase {
    func testMissingItemReturnsNil() throws {
        let key = try KeychainStore.readAPIKey(for: URL(string: "https://api.example.com/v1")!) { _, _ in
            errSecItemNotFound
        }
        XCTAssertNil(key)
    }

    func testUnexpectedStatusIsPropagated() {
        XCTAssertThrowsError(try KeychainStore.readAPIKey(for: URL(string: "https://api.example.com/v1")!) { _, _ in
            errSecAuthFailed
        }) { error in
            guard case KeychainStore.KeychainError.unexpectedStatus(let status) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(status, errSecAuthFailed)
        }
    }

    func testAPIKeyQueryUsesCanonicalEndpointAsAccount() throws {
        var accounts: [String] = []
        let copy: KeychainStore.CopyMatching = { query, _ in
            let values = query as NSDictionary
            accounts.append(values[kSecAttrAccount as String] as! String)
            return errSecItemNotFound
        }

        _ = try KeychainStore.readAPIKey(for: URL(string: "https://API.EXAMPLE/v1/")!, copyMatching: copy)
        _ = try KeychainStore.readAPIKey(for: URL(string: "https://api.example:443/v1")!, copyMatching: copy)
        _ = try KeychainStore.readAPIKey(for: URL(string: "https://api.example:8443/v1")!, copyMatching: copy)
        _ = try KeychainStore.readAPIKey(for: URL(string: "https://api.example/v2")!, copyMatching: copy)
        _ = try KeychainStore.readAPIKey(for: URL(string: "http://api.example/v1")!, copyMatching: copy)

        XCTAssertEqual(accounts, [
            "https://api.example:443/v1",
            "https://api.example:443/v1",
            "https://api.example:8443/v1",
            "https://api.example:443/v2",
            "http://api.example:80/v1",
        ])
    }

    func testAPIKeyAccountsDistinguishEndpointQueries() throws {
        var accounts: [String] = []
        let copy: KeychainStore.CopyMatching = { query, _ in
            let values = query as NSDictionary
            accounts.append(values[kSecAttrAccount as String] as! String)
            return errSecItemNotFound
        }

        _ = try KeychainStore.readAPIKey(
            for: URL(string: "https://api.example/v1?tenant=A")!,
            copyMatching: copy
        )
        _ = try KeychainStore.readAPIKey(
            for: URL(string: "https://api.example/v1?tenant=B")!,
            copyMatching: copy
        )

        XCTAssertEqual(accounts, [
            "https://api.example:443/v1?tenant=A",
            "https://api.example:443/v1?tenant=B",
        ])
    }

    func testAPIKeyAccountsDistinguishEncodedAndLiteralPathSeparators() throws {
        var accounts: [String] = []
        let copy: KeychainStore.CopyMatching = { query, _ in
            let values = query as NSDictionary
            accounts.append(values[kSecAttrAccount as String] as! String)
            return errSecItemNotFound
        }

        _ = try KeychainStore.readAPIKey(
            for: URL(string: "https://api.example/v1%2Ftenant")!,
            copyMatching: copy
        )
        _ = try KeychainStore.readAPIKey(
            for: URL(string: "https://api.example/v1/tenant")!,
            copyMatching: copy
        )

        XCTAssertEqual(accounts, [
            "https://api.example:443/v1%2Ftenant",
            "https://api.example:443/v1/tenant",
        ])
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
    private func keyEvent(keyCode: CGKeyCode, flags: CGEventFlags = [], keyDown: Bool = true) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)!
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
        let box = Box<(UInt32?, UInt32?, String)?>(nil)
        var tapOptions: CGEventTapOptions?
        var eventWasConsumed = false
        let session = RecordingSession(
            completion: { keyCode, modifiers, reason in
                box.value = (keyCode, modifiers, reason)
            },
            requestAccess: { true },
            tapFactory: { options, _, callback, userInfo in
                tapOptions = options
                let event = self.keyEvent(
                    keyCode: CGKeyCode(kVK_ANSI_Q),
                    flags: [.maskCommand]
                )
                eventWasConsumed = callback(
                    CGEventTapProxy(bitPattern: 1)!,
                    .keyDown,
                    event,
                    userInfo
                ) == nil
                return nil
            }
        )
        HotkeyRecorder.currentSession = session

        session.start()

        XCTAssertNil(box.value?.0)
        XCTAssertEqual(tapOptions, .defaultTap)
        XCTAssertTrue(eventWasConsumed)
        XCTAssertEqual(box.value?.2, "Could not capture keyboard events; check Accessibility permission.")
        XCTAssertNil(HotkeyRecorder.currentSession)
    }

    func testStartDoesNotCreateTapAfterSessionFinishesDuringPermissionRequest() {
        let box = Box<(UInt32?, UInt32?, String)?>(nil)
        var tapCreationAttempted = false
        let session = RecordingSession(
            completion: { keyCode, modifiers, reason in
                box.value = (keyCode, modifiers, reason)
            },
            requestAccess: {
                NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
                return true
            },
            tapFactory: { _, _, _, _ in
                tapCreationAttempted = true
                return nil
            }
        )
        HotkeyRecorder.currentSession = session

        session.start()

        XCTAssertEqual(box.value?.2, "Cancelled.")
        XCTAssertFalse(tapCreationAttempted)
        XCTAssertNil(HotkeyRecorder.currentSession)
    }

    func testStartReportsDeniedAccessibilityWithoutCreatingTap() {
        let box = Box<(UInt32?, UInt32?, String)?>(nil)
        var tapCreationAttempted = false
        let session = RecordingSession(
            completion: { keyCode, modifiers, reason in
                box.value = (keyCode, modifiers, reason)
            },
            requestAccess: { false },
            tapFactory: { _, _, _, _ in
                tapCreationAttempted = true
                return nil
            }
        )
        HotkeyRecorder.currentSession = session

        session.start()

        XCTAssertEqual(box.value?.2, "Accessibility permission is required to record a hotkey.")
        XCTAssertFalse(tapCreationAttempted)
        XCTAssertNil(HotkeyRecorder.currentSession)
    }

    func testHandleCapturesCommandOptionCombo() {
        let (session, box) = makeSession()
        session.handle(keyEvent(keyCode: CGKeyCode(kVK_ANSI_J), flags: [.maskCommand, .maskAlternate]))
        XCTAssertNil(box.value)
        XCTAssertTrue(HotkeyRecorder.currentSession === session)
        session.handle(keyEvent(keyCode: CGKeyCode(kVK_ANSI_J), keyDown: false))
        XCTAssertEqual(box.value?.0, UInt32(kVK_ANSI_J))
        XCTAssertEqual(box.value?.1, UInt32(cmdKey | optionKey))
        XCTAssertEqual(box.value?.2, "⌥⌘J")
        XCTAssertNil(HotkeyRecorder.currentSession)
    }

    func testHandleEscapeCancelsWithoutRebinding() {
        let (session, box) = makeSession()
        session.handle(keyEvent(keyCode: CGKeyCode(kVK_Escape), flags: [.maskCommand]))
        XCTAssertNil(box.value)
        XCTAssertTrue(HotkeyRecorder.currentSession === session)
        session.handle(keyEvent(keyCode: CGKeyCode(kVK_Escape), keyDown: false))
        XCTAssertNil(box.value?.0)
        XCTAssertEqual(box.value?.2, "Cancelled.")
        XCTAssertNil(HotkeyRecorder.currentSession)
    }

    func testHandleReservedComboIsRejected() {
        let (session, box) = makeSession()
        session.handle(keyEvent(keyCode: CGKeyCode(kVK_ANSI_C), flags: [.maskCommand]))
        XCTAssertNil(box.value)
        XCTAssertTrue(HotkeyRecorder.currentSession === session)
        session.handle(keyEvent(keyCode: CGKeyCode(kVK_ANSI_C), keyDown: false))
        XCTAssertNil(box.value?.0)
        XCTAssertEqual(box.value?.2, "That combination conflicts with a common system shortcut.")
        XCTAssertNil(HotkeyRecorder.currentSession)
    }

    func testFirstQualifyingKeyDownRemainsPendingUntilItsKeyUp() {
        let (session, box) = makeSession()
        session.handle(keyEvent(keyCode: CGKeyCode(kVK_ANSI_C), flags: [.maskCommand]))
        session.handle(keyEvent(keyCode: CGKeyCode(kVK_ANSI_J), flags: [.maskCommand]))
        session.handle(keyEvent(keyCode: CGKeyCode(kVK_ANSI_C), keyDown: false))

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
        let (_, box) = makeSession()
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
        HotkeyRecorder.start(
            requestAccess: { true },
            tapFactory: { _, _, _, _ in nil },
            completion: { keyCode, modifiers, reason in
                secondBox.value = (keyCode, modifiers, reason)
            }
        )
        let second = HotkeyRecorder.currentSession

        XCTAssertNil(firstBox.value)
        XCTAssertFalse(HotkeyRecorder.currentSession === first)
        XCTAssertNil(second)
        XCTAssertNil(secondBox.value?.0)
        XCTAssertEqual(secondBox.value?.2, "Could not capture keyboard events; check Accessibility permission.")
    }
}

@MainActor
final class AppModelHotkeyTests: XCTestCase {
    func testFailedAdoptionKeepsPersistedHotkeyRegisteredAfterSuppression() {
        let hotkeys = StubHotkeyManager(registrationResults: [true, false])
        let settings = AppSettings(
            baseURL: "https://api.example.com/v1",
            model: "test-model",
            hotkeyKeyCode: kVK_ANSI_P,
            hotkeyModifiers: cmdKey | optionKey
        )
        let model = AppModel(settings: settings, hotkeyCenter: hotkeys)

        model.suspendHotkey()
        XCTAssertTrue(hotkeys.isTriggerSuppressed)
        XCTAssertEqual(hotkeys.activeKeyCode, UInt32(kVK_ANSI_P))
        XCTAssertFalse(model.adoptHotkey(keyCode: kVK_ANSI_J, modifiers: cmdKey | optionKey))

        XCTAssertEqual(hotkeys.registrations.count, 2)
        XCTAssertEqual(hotkeys.registrations[0].0, UInt32(kVK_ANSI_P))
        XCTAssertEqual(hotkeys.registrations[1].0, UInt32(kVK_ANSI_J))
        XCTAssertEqual(hotkeys.registrations.map(\.1), Array(repeating: UInt32(cmdKey | optionKey), count: 2))
        XCTAssertEqual(model.settings.hotkeyKeyCode, kVK_ANSI_P)
        XCTAssertEqual(hotkeys.activeKeyCode, UInt32(kVK_ANSI_P))
        XCTAssertTrue(hotkeys.isTriggerSuppressed)

        model.resumeHotkey()

        XCTAssertFalse(hotkeys.isTriggerSuppressed)
    }

    func testSuccessfulAdoptionRemainsSuppressedUntilExplicitlyResumed() {
        let hotkeys = StubHotkeyManager(registrationResults: [true, true])
        let model = AppModel(
            settings: AppSettings(baseURL: "https://api.example.com/v1", model: "test-model"),
            hotkeyCenter: hotkeys
        )

        model.suspendHotkey()
        XCTAssertTrue(model.adoptHotkey(keyCode: kVK_ANSI_J, modifiers: cmdKey | optionKey))

        XCTAssertTrue(hotkeys.isTriggerSuppressed)
        model.resumeHotkey()
        XCTAssertFalse(hotkeys.isTriggerSuppressed)
    }

    func testUnreadableSettingsAreNotPersistedByUnrelatedUpdates() {
        var persisted: [AppSettings] = []
        let hotkeys = StubHotkeyManager(registrationResults: [true, true])
        let model = AppModel(
            settings: AppSettings(baseURL: "", model: ""),
            settingsAreReadable: false,
            hotkeyCenter: hotkeys,
            persistSettings: { persisted.append($0) }
        )

        model.update { $0.preset = .formal }
        XCTAssertTrue(model.adoptHotkey(keyCode: kVK_ANSI_J, modifiers: cmdKey | optionKey))

        XCTAssertFalse(model.settingsAreReadable)
        XCTAssertTrue(persisted.isEmpty)
    }

    func testValidEndpointReconfigurationPersistsAndRestoresReadableState() {
        var persisted: [AppSettings] = []
        let model = AppModel(
            settings: AppSettings(baseURL: "", model: "", preset: .formal),
            settingsAreReadable: false,
            hotkeyCenter: StubHotkeyManager(registrationResults: [true]),
            persistSettings: { persisted.append($0) }
        )
        model.lastOutcome = .failure("Settings are unreadable. Re-open Refinery settings to reconfigure the endpoint.")

        XCTAssertTrue(model.updateEndpoint(baseURL: " https://api.example.com/v1 ", model: " model "))

        XCTAssertTrue(model.settingsAreReadable)
        XCTAssertEqual(model.settings.baseURL, "https://api.example.com/v1")
        XCTAssertEqual(model.settings.model, "model")
        XCTAssertEqual(persisted, [model.settings])
        XCTAssertNil(model.lastOutcome)
    }

    func testInvalidEndpointReconfigurationLeavesUnreadableStateUntouched() {
        var persisted: [AppSettings] = []
        let model = AppModel(
            settings: AppSettings(baseURL: "", model: ""),
            settingsAreReadable: false,
            hotkeyCenter: StubHotkeyManager(registrationResults: [true]),
            persistSettings: { persisted.append($0) }
        )

        XCTAssertFalse(model.updateEndpoint(baseURL: "http://api.example.com/v1", model: "model"))

        XCTAssertFalse(model.settingsAreReadable)
        XCTAssertTrue(persisted.isEmpty)
    }
}

final class AppSettingsTests: XCTestCase {
    func testMissingSettingsUseFirstRunDefaults() throws {
        let defaults = makeDefaults()
        let settings = try AppSettings.load(from: defaults)
        XCTAssertEqual(settings.baseURL, "https://api.ucloud-ai.com/v1")
        XCTAssertEqual(settings.model, "ucloud-ai")
    }

    func testUnreadableSettingsDoNotFallBackToProviderDefaults() {
        let defaults = makeDefaults()
        defaults.set(Data("not-json".utf8), forKey: AppSettings.defaultsKey)
        XCTAssertThrowsError(try AppSettings.load(from: defaults)) {
            XCTAssertTrue($0 is AppSettings.LoadError)
        }
    }

    func testOutOfRangeHotkeyValuesAreUnreadable() throws {
        for (keyCode, modifiers) in [(-1, 2304), (35, -1), (Int(UInt32.max) + 1, 2304)] {
            let defaults = makeDefaults()
            let settings = AppSettings(
                baseURL: "https://api.example.com/v1",
                model: "test-model",
                hotkeyKeyCode: keyCode,
                hotkeyModifiers: modifiers
            )
            settings.save(to: defaults)

            XCTAssertThrowsError(try AppSettings.load(from: defaults)) {
                XCTAssertTrue($0 is AppSettings.LoadError)
            }
        }
    }

    func testUnsafePersistedSettingsAreUnreadable() {
        let unsafeSettings = [
            AppSettings(baseURL: "https://api.example.com/v1", model: "test-model", hotkeyKeyCode: 0, hotkeyModifiers: 0),
            AppSettings(baseURL: "https://api.example.com/v1", model: "test-model", hotkeyKeyCode: 35, hotkeyModifiers: shiftKey),
            AppSettings(baseURL: "https://api.example.com/v1", model: "test-model", hotkeyKeyCode: 35, hotkeyModifiers: cmdKey | 1),
            AppSettings(baseURL: "https://api.example.com/v1", model: "test-model", hotkeyKeyCode: 128, hotkeyModifiers: cmdKey),
            AppSettings(baseURL: "https://api.example.com/v1", model: "test-model", hotkeyKeyCode: kVK_ANSI_C, hotkeyModifiers: cmdKey),
            AppSettings(baseURL: "https://api.example.com/v1", model: "test-model", hotkeyKeyCode: kVK_Command, hotkeyModifiers: cmdKey),
            AppSettings(baseURL: "https://api.example.com/v1", model: "   ", hotkeyKeyCode: 35, hotkeyModifiers: cmdKey),
        ]

        for settings in unsafeSettings {
            let defaults = makeDefaults()
            settings.save(to: defaults)
            XCTAssertThrowsError(try AppSettings.load(from: defaults)) {
                XCTAssertTrue($0 is AppSettings.LoadError)
            }
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "RefineryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

final class ClipboardStoreTests: XCTestCase {
    func testWriteReportsSuccessAndPreservesText() {
        let pasteboard = NSPasteboard(name: .init("RefineryTests.\(UUID().uuidString)"))
        XCTAssertTrue(ClipboardStore.write("  polished\n", to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "  polished\n")
    }

    func testFailedWriteRestoresEveryPreviousRepresentation() {
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        item.setData(Data([0x00, 0x7f, 0xff]), forType: .init("com.refinery.binary"))
        let pasteboard = FailingPasteboard(items: [item])

        XCTAssertFalse(ClipboardStore.write("polished", to: pasteboard))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.string(forType: .string), "original")
        XCTAssertEqual(
            pasteboard.pasteboardItems?.first?.data(forType: .init("com.refinery.binary")),
            Data([0x00, 0x7f, 0xff])
        )
    }
}

private final class FailingPasteboard: PasteboardAccess {
    var pasteboardItems: [NSPasteboardItem]?

    init(items: [NSPasteboardItem]) {
        pasteboardItems = items
    }

    func clearContents() -> Int {
        pasteboardItems = nil
        return 0
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        false
    }

    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        pasteboardItems = objects.compactMap { $0 as? NSPasteboardItem }
        return true
    }
}

/// A tiny reference box for capturing completion results from tests.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
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

@MainActor
private final class StubHotkeyManager: HotkeyManaging {
    var onTrigger: (() -> Void)?
    var registrations: [(UInt32, UInt32)] = []
    private(set) var activeKeyCode: UInt32?
    private(set) var isTriggerSuppressed = false
    private var registrationResults: [Bool]

    init(registrationResults: [Bool]) {
        self.registrationResults = registrationResults
    }

    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        registrations.append((keyCode, modifiers))
        let result = registrationResults.removeFirst()
        if result {
            activeKeyCode = keyCode
        }
        return result
    }

    func suspend() {
        isTriggerSuppressed = true
    }

    func resume() {
        isTriggerSuppressed = false
    }
}
