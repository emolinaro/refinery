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
    func testSuppressedEventDoesNotTrigger() {
        let center = HotkeyCenter()
        var triggerCount = 0
        center.onTrigger = { triggerCount += 1 }
        center.suspend()

        center.handleMatchedHotkeyEvent()
        center.resume()

        XCTAssertEqual(triggerCount, 0)
    }

    func testUnsuppressedEventTriggersBeforeHandlerReturns() {
        let center = HotkeyCenter()
        var triggerCount = 0
        center.onTrigger = { triggerCount += 1 }

        center.handleMatchedHotkeyEvent()

        XCTAssertEqual(triggerCount, 1)
    }

    func testRegistrationRequestsExclusiveOwnership() {
        var receivedOptions: OptionBits?
        let center = HotkeyCenter { _, _, _, options, _ in
            receivedOptions = options
            return OSStatus(eventHotKeyExistsErr)
        }

        XCTAssertFalse(center.register(
            keyCode: UInt32(kVK_ANSI_J),
            modifiers: UInt32(cmdKey | optionKey)
        ))
        XCTAssertEqual(receivedOptions, OptionBits(kEventHotKeyExclusive))
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

    func testLiveTransportLimitsRequestAndResourceDuration() {
        let configuration = EndpointClient.transportConfiguration(timeout: 5)

        XCTAssertEqual(configuration.timeoutIntervalForRequest, 5)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 5)
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
            let data = Data(#"{"choices":[{"message":{"content":"  indented\n"},"finish_reason":"stop"}]}"#.utf8)
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

    func testMissingOrNullFinishReasonSurfacesIncompleteError() async {
        let payloads = [
            #"{"choices":[{"message":{"content":"Partial"}}]}"#,
            #"{"choices":[{"message":{"content":"Partial"},"finish_reason":null}]}"#,
        ]

        for payload in payloads {
            let response: EndpointClient.Transport = { request in
                (Data(payload.utf8), HTTPURLResponse(
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
            "https://api.example:443/v1/chat/completions",
            "https://api.example:443/v1/chat/completions",
            "https://api.example:8443/v1/chat/completions",
            "https://api.example:443/v2/chat/completions",
            "http://api.example:80/v1/chat/completions",
        ])
    }

    func testAPIKeyAccountsDistinguishRepeatedTrailingSeparators() throws {
        var accounts: [String] = []
        let copy: KeychainStore.CopyMatching = { query, _ in
            let values = query as NSDictionary
            accounts.append(values[kSecAttrAccount as String] as! String)
            return errSecItemNotFound
        }

        _ = try KeychainStore.readAPIKey(
            for: URL(string: "https://api.example/v1")!,
            copyMatching: copy
        )
        _ = try KeychainStore.readAPIKey(
            for: URL(string: "https://api.example/v1//")!,
            copyMatching: copy
        )

        XCTAssertEqual(accounts, [
            "https://api.example:443/v1/chat/completions",
            "https://api.example:443/v1//chat/completions",
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
            "https://api.example:443/v1/chat/completions?tenant=A",
            "https://api.example:443/v1/chat/completions?tenant=B",
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
            "https://api.example:443/v1%2Ftenant/chat/completions",
            "https://api.example:443/v1/tenant/chat/completions",
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
        var tapLocation: CGEventTapLocation?
        var tapPlacement: CGEventTapPlacement?
        var tapOptions: CGEventTapOptions?
        var eventWasConsumed = false
        let session = RecordingSession(
            completion: { keyCode, modifiers, reason in
                box.value = (keyCode, modifiers, reason)
            },
            requestAccess: { true },
            tapFactory: { location, placement, options, _, callback, userInfo in
                tapLocation = location
                tapPlacement = placement
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
        XCTAssertEqual(tapLocation, .cgSessionEventTap)
        XCTAssertEqual(tapPlacement, .headInsertEventTap)
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
            tapFactory: { _, _, _, _, _, _ in
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
            tapFactory: { _, _, _, _, _, _ in
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

    func testTapDisabledByTimeoutIsReenabled() throws {
        let port = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
        var callback: CGEventTapCallBack?
        var userInfo: UnsafeMutableRawPointer?
        var enableCount = 0
        let session = RecordingSession(
            completion: { _, _, _ in },
            requestAccess: { true },
            tapFactory: { _, _, _, _, capturedCallback, capturedUserInfo in
                callback = capturedCallback
                userInfo = capturedUserInfo
                return port
            },
            tapEnabler: { _ in enableCount += 1 }
        )
        HotkeyRecorder.currentSession = session
        session.start()

        _ = try XCTUnwrap(callback)(
            CGEventTapProxy(bitPattern: 1)!,
            .tapDisabledByTimeout,
            keyEvent(keyCode: CGKeyCode(kVK_ANSI_P)),
            try XCTUnwrap(userInfo)
        )

        XCTAssertEqual(enableCount, 2)
        XCTAssertTrue(HotkeyRecorder.currentSession === session)
        session.invalidate()
    }

    func testTapDisabledByUserInputEndsRecordingWithFeedback() throws {
        let port = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
        let box = Box<(UInt32?, UInt32?, String)?>(nil)
        var callback: CGEventTapCallBack?
        var userInfo: UnsafeMutableRawPointer?
        let session = RecordingSession(
            completion: { keyCode, modifiers, reason in
                box.value = (keyCode, modifiers, reason)
            },
            requestAccess: { true },
            tapFactory: { _, _, _, _, capturedCallback, capturedUserInfo in
                callback = capturedCallback
                userInfo = capturedUserInfo
                return port
            },
            tapEnabler: { _ in }
        )
        HotkeyRecorder.currentSession = session
        session.start()

        _ = try XCTUnwrap(callback)(
            CGEventTapProxy(bitPattern: 1)!,
            .tapDisabledByUserInput,
            keyEvent(keyCode: CGKeyCode(kVK_ANSI_P)),
            try XCTUnwrap(userInfo)
        )

        XCTAssertNil(box.value?.0)
        XCTAssertEqual(box.value?.2, "Keyboard capture was disabled; try recording the hotkey again.")
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

    func testExplicitCancellationEndsSessionAndClearsCurrentSession() {
        let (_, box) = makeSession()

        HotkeyRecorder.cancel()

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
            tapFactory: { _, _, _, _, _, _ in nil },
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

    func testSuccessfulAdoptionClearsPriorRegistrationFailure() {
        let hotkeys = StubHotkeyManager(registrationResults: [false, true])
        let model = AppModel(
            settings: AppSettings(baseURL: "https://api.example.com/v1", model: "test-model"),
            hotkeyCenter: hotkeys
        )
        XCTAssertNotNil(model.lastOutcome)

        XCTAssertTrue(model.adoptHotkey(keyCode: kVK_ANSI_J, modifiers: cmdKey | optionKey))

        XCTAssertNil(model.lastOutcome)
    }

    func testSuccessfulAdoptionPreservesUnrelatedFailure() {
        let hotkeys = StubHotkeyManager(registrationResults: [true, true])
        let model = AppModel(
            settings: AppSettings(baseURL: "https://api.example.com/v1", model: "test-model"),
            hotkeyCenter: hotkeys
        )
        model.lastOutcome = .failure("Endpoint failure")

        XCTAssertTrue(model.adoptHotkey(keyCode: kVK_ANSI_J, modifiers: cmdKey | optionKey))

        XCTAssertEqual(model.lastOutcome, .failure("Endpoint failure"))
    }

    func testClosingSettingsCancelsRecordingAndResumesHotkey() {
        let hotkeys = StubHotkeyManager(registrationResults: [true])
        let model = AppModel(
            settings: AppSettings(baseURL: "https://api.example.com/v1", model: "test-model"),
            hotkeyCenter: hotkeys
        )
        let cancellation = Box<(UInt32?, UInt32?, String)?>(nil)
        HotkeyRecorder.currentSession = RecordingSession { keyCode, modifiers, reason in
            cancellation.value = (keyCode, modifiers, reason)
        }
        model.suspendHotkey()

        model.cancelHotkeyRecording()

        XCTAssertEqual(cancellation.value?.2, "Cancelled.")
        XCTAssertNil(HotkeyRecorder.currentSession)
        XCTAssertFalse(hotkeys.isTriggerSuppressed)
    }

    func testSelectionValidationDoesNotBlockMainActor() async throws {
        _ = NSApplication.shared
        let readStarted = expectation(description: "selection read started")
        let releaseRead = DispatchSemaphore(value: 0)
        let selectionContext = makeSelectionContext(processIdentifier: 101)
        let model = AppModel(
            settings: AppSettings(baseURL: "https://api.example.com/v1", model: "test-model"),
            hotkeyCenter: StubHotkeyManager(registrationResults: [true]),
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            captureSelection: { _ in .accessibility(selectionContext) },
            readSelection: { _ in
                readStarted.fulfill()
                return releaseRead.wait(timeout: .now() + 1) == .success
                    ? .noSelection
                    : .unreadable
            }
        )

        let startedAt = Date()
        model.handleHotkey()

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.25)
        await fulfillment(of: [readStarted], timeout: 1)
        XCTAssertTrue(model.isRunning)
        releaseRead.signal()

        for _ in 0..<100 where model.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.lastOutcome, .emptySelection)
    }

    func testSelectionReadUsesContextCapturedAtHotkeyInvocation() async throws {
        _ = NSApplication.shared
        let readFinished = expectation(description: "selection read finished")
        let capturedProcessIdentifier = LockedBox<pid_t?>(nil)
        var frontmostProcessIdentifier: pid_t = 101
        let selectionContext = makeSelectionContext(processIdentifier: 101)
        let model = AppModel(
            settings: AppSettings(baseURL: "https://api.example.com/v1", model: "test-model"),
            hotkeyCenter: StubHotkeyManager(registrationResults: [true]),
            accessibilityEnabled: { true },
            frontmostApplicationPID: { frontmostProcessIdentifier },
            captureSelection: { _ in .accessibility(selectionContext) },
            readSelection: { context in
                capturedProcessIdentifier.set(context.processIdentifier)
                readFinished.fulfill()
                return .noSelection
            }
        )

        model.handleHotkey()
        frontmostProcessIdentifier = 202

        await fulfillment(of: [readFinished], timeout: 1)
        for _ in 0..<100 where model.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(capturedProcessIdentifier.get(), 101)
        XCTAssertEqual(model.lastOutcome, .emptySelection)
    }

    func testRequestUsesConfigurationCapturedAtHotkeyInvocation() async throws {
        _ = NSApplication.shared
        let readStarted = expectation(description: "selection read started")
        let releaseRead = DispatchSemaphore(value: 0)
        let capturedRequest = LockedBox<CapturedPolishRequest?>(nil)
        let capturedClipboard = LockedBox<String?>(nil)
        let selectionContext = makeSelectionContext(processIdentifier: 101)
        var currentAPIKey = "original-key"
        let model = AppModel(
            settings: AppSettings(
                baseURL: "https://original.example.com/v1",
                model: "original-model",
                preset: .formal
            ),
            hotkeyCenter: StubHotkeyManager(registrationResults: [true]),
            persistSettings: { _ in },
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            captureSelection: { _ in .accessibility(selectionContext) },
            readSelection: { _ in
                readStarted.fulfill()
                return releaseRead.wait(timeout: .now() + 1) == .success
                    ? .selected("selected text")
                    : .unreadable
            },
            readAPIKey: { _ in currentAPIKey },
            polish: { baseURL, model, text, preset, custom, key in
                capturedRequest.set(CapturedPolishRequest(
                    baseURL: baseURL,
                    model: model,
                    text: text,
                    preset: preset,
                    customPrompt: custom,
                    apiKey: key
                ))
                return "polished text"
            },
            writeClipboard: { text, _ in
                capturedClipboard.set(text)
                return .success(())
            }
        )

        model.handleHotkey()
        await fulfillment(of: [readStarted], timeout: 1)
        model.settings.baseURL = "https://changed.example.com/v1"
        model.settings.model = "changed-model"
        model.settings.preset = .concise
        currentAPIKey = "changed-key"
        releaseRead.signal()

        for _ in 0..<100 where model.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(capturedRequest.get(), CapturedPolishRequest(
            baseURL: URL(string: "https://original.example.com/v1")!,
            model: "original-model",
            text: "selected text",
            preset: .formal,
            customPrompt: nil,
            apiKey: "original-key"
        ))
        XCTAssertEqual(capturedClipboard.get(), "polished text")
        XCTAssertEqual(model.lastOutcome, .polished)
    }

    func testSelectionOutcomePrecedesCapturedCredentialFailure() async throws {
        _ = NSApplication.shared
        let selectionContext = makeSelectionContext(processIdentifier: 101)
        let model = AppModel(
            settings: AppSettings(baseURL: "https://api.example.com/v1", model: "test-model"),
            hotkeyCenter: StubHotkeyManager(registrationResults: [true]),
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            captureSelection: { _ in .accessibility(selectionContext) },
            readSelection: { _ in .noSelection },
            readAPIKey: { _ in
                throw NSError(domain: "CredentialFailure", code: 1)
            }
        )

        model.handleHotkey()

        for _ in 0..<100 where model.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.lastOutcome, .emptySelection)
    }

    func testAXHostileCaptureUsesClipboardProbeWithoutRebindingTheProcess() async throws {
        _ = NSApplication.shared
        let capturedRequest = LockedBox<CapturedPolishRequest?>(nil)
        let probedProcessIdentifier = LockedBox<pid_t?>(nil)
        let clipboardContext = SelectionReader.ClipboardContext(
            processIdentifier: 101,
            element: AXUIElementCreateApplication(101)
        )
        let model = AppModel(
            settings: AppSettings(baseURL: "https://api.example.com/v1", model: "test-model"),
            hotkeyCenter: StubHotkeyManager(registrationResults: [true]),
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            captureSelection: { _ in .clipboardProbe(clipboardContext) },
            readSelection: { _ in XCTFail("AX read must not run for an AX-hostile capture"); return .unreadable },
            probeClipboardSelection: { context, _ in
                probedProcessIdentifier.set(context.processIdentifier)
                return .clipboardSelection(
                    "Sublime selection",
                    expectedChangeCount: 0
                )
            },
            readAPIKey: { _ in "test-key" },
            polish: { baseURL, model, text, preset, custom, key in
                capturedRequest.set(CapturedPolishRequest(
                    baseURL: baseURL,
                    model: model,
                    text: text,
                    preset: preset,
                    customPrompt: custom,
                    apiKey: key
                ))
                return "polished"
            },
            writeClipboard: { _, _ in .success(()) }
        )

        model.handleHotkey()

        for _ in 0..<100 where model.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(probedProcessIdentifier.get(), 101)
        XCTAssertEqual(capturedRequest.get()?.text, "Sublime selection")
        XCTAssertEqual(model.lastOutcome, .polished)
    }

    func testFallbackPreservesCopyMadeWhileEndpointRequestIsRunning() async throws {
        _ = NSApplication.shared
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        let pasteboard = FailingPasteboard(
            items: [original],
            setStringSucceeds: true
        )
        let clipboardContext = SelectionReader.ClipboardContext(
            processIdentifier: 101,
            element: AXUIElementCreateApplication(101)
        )
        let fallbackWriteChangeCount = pasteboard.changeCount
        let model = AppModel(
            settings: AppSettings(baseURL: "https://api.example.com/v1", model: "test-model"),
            hotkeyCenter: StubHotkeyManager(registrationResults: [true]),
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            captureSelection: { _ in .clipboardProbe(clipboardContext) },
            probeClipboardSelection: { _, _ in
                .clipboardSelection(
                    "Sublime selection",
                    expectedChangeCount: fallbackWriteChangeCount
                )
            },
            readAPIKey: { _ in "test-key" },
            polish: { _, _, _, _, _, _ in
                _ = pasteboard.clearContents()
                XCTAssertTrue(
                    pasteboard.setString("newer user copy", forType: .string)
                )
                return "polished"
            },
            writeClipboard: { text, expectedChangeCount in
                ClipboardStore.writeResult(
                    text,
                    to: pasteboard,
                    ifUnchangedSince: expectedChangeCount
                )
            }
        )

        model.handleHotkey()

        for _ in 0..<100 where model.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "newer user copy"
        )
        XCTAssertEqual(
            model.lastOutcome,
            .failure(ClipboardError.clipboardChanged.localizedDescription)
        )
    }

    func testQuitWaitsForClipboardOwnershipToEndSafely() async throws {
        _ = NSApplication.shared
        let ownershipBegan = expectation(description: "clipboard ownership began")
        let terminationReply = expectation(description: "termination reply")
        let replyValue = Box<Bool?>(nil)
        let gate = AsyncStream<Void>.makeStream()
        let clipboardContext = SelectionReader.ClipboardContext(
            processIdentifier: 101,
            element: AXUIElementCreateApplication(101)
        )
        let model = AppModel(
            settings: AppSettings(baseURL: "https://api.example.com/v1", model: "test-model"),
            hotkeyCenter: StubHotkeyManager(registrationResults: [true]),
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            captureSelection: { _ in .clipboardProbe(clipboardContext) },
            probeClipboardSelection: { _, ownershipChanged in
                ownershipChanged(.began)
                ownershipBegan.fulfill()
                for await _ in gate.stream.prefix(1) {}
                ownershipChanged(.endedSafely)
                return .noSelection
            }
        )

        model.handleHotkey()
        await fulfillment(of: [ownershipBegan], timeout: 1)
        let deferred = model.deferTerminationUntilClipboardRestored { shouldTerminate in
            replyValue.value = shouldTerminate
            terminationReply.fulfill()
        }

        XCTAssertTrue(deferred)
        XCTAssertTrue(model.isFinishingClipboardRestore)
        XCTAssertNil(replyValue.value)

        gate.continuation.yield()
        gate.continuation.finish()
        await fulfillment(of: [terminationReply], timeout: 1)

        XCTAssertFalse(model.isFinishingClipboardRestore)
        XCTAssertEqual(replyValue.value, true)
    }

    func testQuitIsCancelledWhenClipboardRestorationFails() async throws {
        _ = NSApplication.shared
        let ownershipBegan = expectation(description: "clipboard ownership began")
        let terminationReply = expectation(description: "termination reply")
        let replyValue = Box<Bool?>(nil)
        let gate = AsyncStream<Void>.makeStream()
        let clipboardContext = SelectionReader.ClipboardContext(
            processIdentifier: 101,
            element: AXUIElementCreateApplication(101)
        )
        let model = AppModel(
            settings: AppSettings(baseURL: "https://api.example.com/v1", model: "test-model"),
            hotkeyCenter: StubHotkeyManager(registrationResults: [true]),
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            captureSelection: { _ in .clipboardProbe(clipboardContext) },
            probeClipboardSelection: { _, ownershipChanged in
                ownershipChanged(.began)
                ownershipBegan.fulfill()
                for await _ in gate.stream.prefix(1) {}
                ownershipChanged(.restorationFailed)
                return .clipboardFailure(.restorationFailed)
            }
        )

        model.handleHotkey()
        await fulfillment(of: [ownershipBegan], timeout: 1)
        let deferred = model.deferTerminationUntilClipboardRestored { shouldTerminate in
            replyValue.value = shouldTerminate
            terminationReply.fulfill()
        }
        XCTAssertTrue(deferred)
        gate.continuation.yield()
        gate.continuation.finish()
        await fulfillment(of: [terminationReply], timeout: 1)

        for _ in 0..<100 where model.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(replyValue.value, false)
        XCTAssertFalse(model.isFinishingClipboardRestore)
        XCTAssertEqual(
            model.lastOutcome,
            .failure(ClipboardError.restorationFailed.localizedDescription)
        )
    }

    func testAXCaptureNeverInvokesClipboardProbe() async throws {
        _ = NSApplication.shared
        let selectionContext = makeSelectionContext(
            processIdentifier: 101,
            selection: .selected("native selection")
        )
        let probeCount = LockedBox(0)
        let model = AppModel(
            settings: AppSettings(baseURL: "https://api.example.com/v1", model: "test-model"),
            hotkeyCenter: StubHotkeyManager(registrationResults: [true]),
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            captureSelection: { _ in .accessibility(selectionContext) },
            readSelection: { _ in .selected("native selection") },
            probeClipboardSelection: { _, _ in
                probeCount.set(probeCount.get() + 1)
                return .selected("wrong selection")
            },
            readAPIKey: { _ in "test-key" },
            polish: { _, _, text, _, _, _ in text },
            writeClipboard: { _, _ in .success(()) }
        )

        model.handleHotkey()

        for _ in 0..<100 where model.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(probeCount.get(), 0)
        XCTAssertEqual(model.lastOutcome, .polished)
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

    func testUnavailablePromisedDataLeavesOriginalClipboardUntouched() {
        let provider = EmptyPasteboardDataProvider()
        let item = NSPasteboardItem()
        let promisedType = NSPasteboard.PasteboardType("com.refinery.promised")
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [promisedType]))
        let pasteboard = FailingPasteboard(items: [item])

        XCTAssertFalse(ClipboardStore.write("polished", to: pasteboard))
        XCTAssertEqual(pasteboard.clearCount, 0)
        XCTAssertTrue(pasteboard.pasteboardItems?.first === item)
    }

    func testUnavailableClipboardSnapshotIsNotCleared() {
        let pasteboard = FailingPasteboard(items: nil)

        let result = ClipboardStore.writeResult("polished", to: pasteboard)

        XCTAssertEqual(result.failure, .snapshotFailed)
        XCTAssertEqual(pasteboard.clearCount, 0)
    }

    func testFailedRestorationReportsClipboardLoss() {
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        let pasteboard = FailingPasteboard(items: [item], writeObjectsSucceeds: false)

        let result = ClipboardStore.writeResult("polished", to: pasteboard)

        XCTAssertEqual(result.failure, .restorationFailed)
        XCTAssertEqual(
            result.failure?.localizedDescription,
            "Could not write the polished text or restore the previous clipboard contents."
        )
    }

    func testSnapshotRestorePreservesEveryPasteboardRepresentation() throws {
        let pasteboard = NSPasteboard(name: .init("RefineryTests.\(UUID().uuidString)"))
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        item.setData(Data([0x00, 0x7f, 0xff]), forType: .init("com.refinery.binary"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let snapshot = try ClipboardStore.snapshot(of: pasteboard).get()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("replacement", forType: .string))
        let expectedChangeCount = pasteboard.changeCount

        XCTAssertNil(ClipboardStore.restoreWithChangeCount(
            snapshot,
            to: pasteboard,
            ifUnchangedSince: expectedChangeCount
        ).failure)

        XCTAssertEqual(pasteboard.pasteboardItems?.first?.string(forType: .string), "original")
        XCTAssertEqual(
            pasteboard.pasteboardItems?.first?.data(forType: .init("com.refinery.binary")),
            Data([0x00, 0x7f, 0xff])
        )
    }

    func testRestorePreservesClipboardChangedAfterSnapshot() throws {
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        let pasteboard = FailingPasteboard(
            items: [original],
            setStringSucceeds: true
        )
        let expectedChangeCount = pasteboard.changeCount
        let snapshot = try ClipboardStore.snapshot(of: pasteboard).get()
        _ = pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("newer clipboard", forType: .string))

        let result = ClipboardStore.restoreWithChangeCount(
            snapshot,
            to: pasteboard,
            ifUnchangedSince: expectedChangeCount
        )

        XCTAssertEqual(result.failure, .clipboardChanged)
        XCTAssertEqual(pasteboard.string(forType: .string), "newer clipboard")
        XCTAssertNotEqual(pasteboard.changeCount, expectedChangeCount)
    }
}

private final class SublimeShapeTree: @unchecked Sendable {
    let application = AXUIElementCreateApplication(101)
    let menuBar = AXUIElementCreateApplication(202)
    let menu = AXUIElementCreateApplication(203)
    let menuItem = AXUIElementCreateApplication(204)

    var capture: SelectionReader.Capture {
        let focusedElement = AXUIElementCreateApplication(101)
        return SelectionReader.capture(
            for: 101,
            elementResolver: { _ in .resolved(focusedElement) },
            processIdentifierReader: { _ in 101 },
            attributeReader: { element, attribute in
                switch attribute as String {
                case kAXRoleAttribute:
                    if CFEqual(element, menuBar) {
                        return (.success, kAXMenuBarRole as CFString)
                    }
                    if CFEqual(element, menu) {
                        return (.success, kAXMenuRole as CFString)
                    }
                    if CFEqual(element, menuItem) {
                        return (.success, kAXMenuItemRole as CFString)
                    }
                    if CFEqual(element, application) {
                        return (.success, kAXApplicationRole as CFString)
                    }
                    return (.success, kAXWindowRole as CFString)
                default:
                    return (.attributeUnsupported, nil)
                }
            }
        )
    }

    func applicationLacksTextSurfaces(for processIdentifier: pid_t) -> Bool {
        SelectionReader.applicationLacksTextSurfaces(
            for: processIdentifier,
            processIdentifierReader: { _ in 101 },
            attributeReader: { element, attribute in
                switch attribute as String {
                case kAXRoleAttribute:
                    if CFEqual(element, menuBar) {
                        return (.success, kAXMenuBarRole as CFString)
                    }
                    if CFEqual(element, menu) {
                        return (.success, kAXMenuRole as CFString)
                    }
                    if CFEqual(element, application) {
                        return (.success, kAXApplicationRole as CFString)
                    }
                    return (.success, kAXMenuItemRole as CFString)
                default:
                    return (.attributeUnsupported, nil)
                }
            },
            childrenReader: { element in
                if CFEqual(element, application) {
                    return (.success, [menuBar])
                }
                if CFEqual(element, menuBar) {
                    return (.success, [menu])
                }
                if CFEqual(element, menu) {
                    // Every menu item reports an endless supply of children, so an
                    // unpruned walk would exceed its cap inside the menu subtree.
                    return (.success, Array(repeating: menuItem, count: 64))
                }
                return (.success, [])
            },
            applicationElement: { _ in application }
        )
    }
}

@MainActor
final class ClipboardSelectionProbeTests: XCTestCase {
    func testSublimeShapedMenuBarOnlyTreeDrivesClipboardProbe() async throws {
        let tree = SublimeShapeTree()
        guard case .clipboardProbe(let context) = tree.capture else {
            return XCTFail("Expected the Sublime-shaped tree to fall back to the clipboard probe")
        }
        let pasteboard = NSPasteboard(name: .init("RefineryTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var waitCount = 0

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { processIdentifier in
                tree.applicationLacksTextSurfaces(for: processIdentifier)
            },
            synthesizeCopy: { true },
            wait: { _ in
                waitCount += 1
                if waitCount == 1 {
                    _ = pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.setString("Sublime selection", forType: .string))
                }
            }
        )

        XCTAssertEqual(
            outcome,
            .clipboardSelection("Sublime selection", expectedChangeCount: pasteboard.changeCount)
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCopyProbeReturnsSelectionAndRestoresEveryRepresentation() async throws {
        let context = clipboardContext()
        let pasteboard = NSPasteboard(name: .init("RefineryTests.\(UUID().uuidString)"))
        let original = NSPasteboardItem()
        original.setString("original clipboard", forType: .string)
        original.setData(Data([0x01, 0x02]), forType: .init("com.refinery.binary"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([original]))
        var waitCount = 0
        let ownershipEvents = LockedBox<[ClipboardSelectionProbe.OwnershipEvent]>([])

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in true },
            ownershipChanged: { event in
                ownershipEvents.set(ownershipEvents.get() + [event])
            },
            synthesizeCopy: { true },
            wait: { _ in
                waitCount += 1
                if waitCount == 1 {
                    _ = pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.setString("Sublime selection", forType: .string))
                }
            }
        )

        guard case .clipboardSelection(let text, let expectedChangeCount) = outcome else {
            return XCTFail("Expected a leased clipboard selection")
        }
        XCTAssertEqual(text, "Sublime selection")
        XCTAssertEqual(expectedChangeCount, pasteboard.changeCount)
        XCTAssertEqual(ownershipEvents.get(), [.began, .endedSafely])
        XCTAssertEqual(waitCount, 1)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.string(forType: .string), "original clipboard")
        XCTAssertEqual(
            pasteboard.pasteboardItems?.first?.data(forType: .init("com.refinery.binary")),
            Data([0x01, 0x02])
        )
    }

    func testCopyProbeDoesNotSynthesizeWhenAccessibilityIsUnavailable() async {
        let context = clipboardContext()
        let pasteboard = NSPasteboard(name: .init("RefineryTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var synthesizeCount = 0

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { false },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in true },
            synthesizeCopy: { synthesizeCount += 1; return true },
            wait: { _ in }
        )

        XCTAssertEqual(outcome, .unreadable)
        XCTAssertEqual(synthesizeCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCopyProbeRevalidatesApplicationCapabilityBeforeSynthesis() async {
        let context = clipboardContext()
        let pasteboard = NSPasteboard(name: .init("RefineryTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var synthesizeCount = 0

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in false },
            synthesizeCopy: { synthesizeCount += 1; return true },
            wait: { _ in }
        )

        XCTAssertEqual(outcome, .unreadable)
        XCTAssertEqual(synthesizeCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCopyProbeRevalidatesChangedApplicationCapabilityBeforeSynthesis() async {
        let context = clipboardContext()
        let pasteboard = NSPasteboard(name: .init("RefineryTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let capabilityReads = LockedBox(0)
        var synthesizeCount = 0

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in
                let read = capabilityReads.get() + 1
                capabilityReads.set(read)
                return read == 1
            },
            synthesizeCopy: { synthesizeCount += 1; return true },
            wait: { _ in }
        )

        XCTAssertEqual(outcome, .unreadable)
        XCTAssertEqual(capabilityReads.get(), 2)
        XCTAssertEqual(synthesizeCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCopyProbeChecksApplicationCapabilityOffMainThread() async {
        let context = clipboardContext()
        let pasteboard = NSPasteboard(name: .init("RefineryTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let capabilityRanOnMainThread = LockedBox<Bool?>(nil)

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in
                capabilityRanOnMainThread.set(Thread.isMainThread)
                return true
            },
            synthesizeCopy: {
                XCTAssertEqual(capabilityRanOnMainThread.get(), false)
                return false
            },
            wait: { _ in }
        )

        XCTAssertEqual(outcome, .unreadable)
        XCTAssertEqual(capabilityRanOnMainThread.get(), false)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCopyProbeLeavesClipboardAvailableDuringCapabilityCheck() async {
        let context = clipboardContext()
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        let pasteboard = FailingPasteboard(
            items: [original],
            setStringSucceeds: true
        )
        let clipboardWasAvailable = LockedBox(false)

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in
                clipboardWasAvailable.set(
                    pasteboard.string(forType: .string) == "original"
                )
                return true
            },
            synthesizeCopy: { false },
            wait: { _ in }
        )

        XCTAssertEqual(outcome, .unreadable)
        XCTAssertTrue(clipboardWasAvailable.get())
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCopyProbeRejectsPasteboardChangesDuringSynthesis() async {
        let context = clipboardContext()
        let pasteboard = NSPasteboard(name: .init("RefineryTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in true },
            synthesizeCopy: {
                _ = pasteboard.clearContents()
                return pasteboard.setString("unattributed writer", forType: .string)
            },
            wait: { _ in }
        )

        XCTAssertEqual(outcome, .clipboardFailure(.clipboardChanged))
        XCTAssertEqual(pasteboard.string(forType: .string), "unattributed writer")
    }

    func testCopyProbeRejectsTextMatchingThePreProbeClipboard() async {
        let context = clipboardContext()
        let pasteboard = NSPasteboard(name: .init("RefineryTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("same text", forType: .string))
        var waitCount = 0

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in true },
            synthesizeCopy: { true },
            wait: { _ in
                waitCount += 1
                if waitCount == 1 {
                    _ = pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.setString("same text", forType: .string))
                }
            }
        )

        XCTAssertEqual(outcome, .noSelection)
        XCTAssertEqual(pasteboard.string(forType: .string), "same text")
    }

    func testCopyProbeRejectsCombinedTextMatchingMultiplePreProbeItems() async {
        let context = clipboardContext()
        let first = NSPasteboardItem()
        first.setString("one", forType: .string)
        let second = NSPasteboardItem()
        second.setString("two", forType: .string)
        let pasteboard = FailingPasteboard(
            items: [first, second],
            setStringSucceeds: true,
            combinesStrings: true
        )
        var waitCount = 0

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in true },
            synthesizeCopy: { true },
            wait: { _ in
                waitCount += 1
                if waitCount == 1 {
                    _ = pasteboard.clearContents()
                    XCTAssertTrue(
                        pasteboard.setString("one\ntwo", forType: .string)
                    )
                }
            }
        )

        XCTAssertEqual(outcome, .noSelection)
        XCTAssertEqual(pasteboard.string(forType: .string), "one\ntwo")
    }

    func testCopyProbeDoesNotSynthesizeAfterFocusChanges() async {
        let context = clipboardContext()
        let pasteboard = NSPasteboard(name: .init("RefineryTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var synthesizeCount = 0

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 202 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in true },
            synthesizeCopy: { synthesizeCount += 1; return true },
            wait: { _ in }
        )

        XCTAssertEqual(outcome, .unreadable)
        XCTAssertEqual(synthesizeCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCopyProbeDoesNotSynthesizeAfterSameProcessFocusChanges() async {
        let context = clipboardContext()
        let replacementElement = AXUIElementCreateApplication(202)
        let pasteboard = NSPasteboard(name: .init("RefineryTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var synthesizeCount = 0

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: { _ in .resolved(replacementElement) },
            applicationLacksTextSurfaces: { _ in true },
            synthesizeCopy: { synthesizeCount += 1; return true },
            wait: { _ in }
        )

        XCTAssertEqual(outcome, .unreadable)
        XCTAssertEqual(synthesizeCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCopyProbeRejectsSelectionAfterSameProcessFocusChanges() async {
        let context = clipboardContext()
        let replacementElement = AXUIElementCreateApplication(202)
        let pasteboard = NSPasteboard(name: .init("RefineryTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var focusResolutionCount = 0
        var waitCount = 0

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: { _ in
                focusResolutionCount += 1
                return .resolved(
                    focusResolutionCount <= 2 ? context.element : replacementElement
                )
            },
            applicationLacksTextSurfaces: { _ in true },
            synthesizeCopy: { true },
            wait: { _ in
                waitCount += 1
                if waitCount == 1 {
                    _ = pasteboard.clearContents()
                    XCTAssertTrue(
                        pasteboard.setString("other control", forType: .string)
                    )
                }
            }
        )

        XCTAssertEqual(outcome, .unreadable)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCopyProbeRejectsInWindowWriteAfterFocusContinuityBreaks() async {
        let context = clipboardContext()
        let pasteboard = NSPasteboard(name: .init("RefineryTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let focusContinuity = StubFocusContinuityMonitor()
        var waitCount = 0

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in true },
            focusContinuityMonitor: { _, _ in focusContinuity },
            synthesizeCopy: { true },
            wait: { _ in
                waitCount += 1
                if waitCount == 1 {
                    focusContinuity.invalidate()
                    _ = pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.setString("unattributed secret", forType: .string))
                }
            }
        )

        XCTAssertEqual(outcome, .unreadable)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCopyProbeRestoresLateFirstCopyAndReportsTimeout() async {
        let context = clipboardContext()
        let pasteboard = NSPasteboard(name: .init("RefineryTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var waitCount = 0

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in true },
            synthesizeCopy: { true },
            wait: { _ in
                waitCount += 1
                if waitCount == 11 {
                    _ = pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.setString("late selection", forType: .string))
                }
            }
        )

        XCTAssertEqual(outcome, .clipboardFailure(.selectionReadTimedOut))
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertEqual(
            ClipboardError.selectionReadTimedOut.localizedDescription,
            "The selection copy arrived too late, so the previous clipboard was restored. Try again."
        )
    }

    func testCopyProbePreservesNewerWriteBeforeRestoration() async {
        let context = clipboardContext()
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        let pasteboard = ChangingAfterObservationPasteboard(items: [original])
        var waitCount = 0

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in true },
            synthesizeCopy: { true },
            wait: { _ in
                waitCount += 1
                if waitCount == 1 {
                    _ = pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.setString("Sublime selection", forType: .string))
                }
            }
        )

        XCTAssertEqual(outcome, .clipboardFailure(.clipboardChanged))
        XCTAssertEqual(pasteboard.string(forType: .string), "newer clipboard")
    }

    func testCopyProbePreservesDelayedWriteAfterRestoration() async {
        let context = clipboardContext()
        let pasteboard = NSPasteboard(name: .init("RefineryTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var waitCount = 0

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in true },
            synthesizeCopy: { true },
            wait: { _ in
                waitCount += 1
                if waitCount == 1 {
                    _ = pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.setString("original", forType: .string))
                } else if waitCount == 2 {
                    _ = pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.setString("newer user copy", forType: .string))
                }
            }
        )

        XCTAssertEqual(outcome, .clipboardFailure(.clipboardChanged))
        XCTAssertEqual(pasteboard.string(forType: .string), "newer user copy")
    }

    func testCopyProbePreservesWriterThatReplacesOwnershipMarker() async {
        let context = clipboardContext()
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        let pasteboard = ReplacingOwnershipPasteboard(items: [original])

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in true },
            synthesizeCopy: { true },
            wait: { _ in }
        )

        XCTAssertEqual(outcome, .clipboardFailure(.clipboardChanged))
        XCTAssertEqual(pasteboard.string(forType: .string), "newer clipboard")
    }

    func testCopyProbePreservesWriteBeforeOwnershipInstallation() async {
        let context = clipboardContext()
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        let pasteboard = ChangingBeforeOwnershipPasteboard(items: [original])
        var synthesizeCount = 0

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in true },
            synthesizeCopy: { synthesizeCount += 1; return false },
            wait: { _ in }
        )

        XCTAssertEqual(outcome, .clipboardFailure(.clipboardChanged))
        XCTAssertEqual(synthesizeCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "newer clipboard")
    }

    func testCopyProbeRejectsConcurrentWriteAfterSnapshotRestoration() async {
        let context = clipboardContext()
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        let pasteboard = ChangingAfterRestorePasteboard(items: [original])
        var waitCount = 0

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in true },
            synthesizeCopy: { true },
            wait: { _ in
                waitCount += 1
                if waitCount == 1 {
                    _ = pasteboard.clearContents()
                    XCTAssertTrue(
                        pasteboard.setString("Sublime selection", forType: .string)
                    )
                }
            }
        )

        XCTAssertEqual(outcome, .clipboardFailure(.clipboardChanged))
        XCTAssertEqual(pasteboard.string(forType: .string), "newer clipboard")
    }

    func testCopyProbeReportsRestorationFailureInsteadOfUsingCopiedText() async {
        let context = clipboardContext()
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        let pasteboard = FailingPasteboard(
            items: [item],
            setStringSucceeds: true,
            writeObjectsResults: [true, false]
        )
        var waitCount = 0
        var ownershipEvents: [ClipboardSelectionProbe.OwnershipEvent] = []

        let outcome = await ClipboardSelectionProbe.read(
            for: context,
            pasteboard: pasteboard,
            accessibilityEnabled: { true },
            frontmostApplicationPID: { 101 },
            focusedElementResolver: focusedElementResolver(for: context),
            applicationLacksTextSurfaces: { _ in true },
            ownershipChanged: { ownershipEvents.append($0) },
            synthesizeCopy: { true },
            wait: { _ in
                waitCount += 1
                if waitCount == 1 {
                    _ = pasteboard.clearContents()
                    XCTAssertTrue(
                        pasteboard.setString("Sublime selection", forType: .string)
                    )
                }
            }
        )

        XCTAssertEqual(outcome, .clipboardFailure(.restorationFailed))
        XCTAssertEqual(ownershipEvents, [.began, .restorationFailed])
    }

    private func clipboardContext(
        processIdentifier: pid_t = 101,
        element: AXUIElement = AXUIElementCreateApplication(101)
    ) -> SelectionReader.ClipboardContext {
        SelectionReader.ClipboardContext(
            processIdentifier: processIdentifier,
            element: element
        )
    }

    private func focusedElementResolver(
        for context: SelectionReader.ClipboardContext
    ) -> (pid_t) -> SelectionReader.ElementResolution {
        { _ in .resolved(context.element) }
    }
}

@MainActor
private final class StubFocusContinuityMonitor: FocusContinuityMonitoring {
    private(set) var remainedFocused = true

    func invalidate() {
        remainedFocused = false
    }

    func stop() {}
}

private final class EmptyPasteboardDataProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {}
}

private final class FailingPasteboard: PasteboardAccess, @unchecked Sendable {
    var pasteboardItems: [NSPasteboardItem]?
    private(set) var changeCount = 0
    private(set) var clearCount = 0
    private let setStringSucceeds: Bool
    private let writeObjectsSucceeds: Bool
    private let combinesStrings: Bool
    private var writeObjectsResults: [Bool]

    init(
        items: [NSPasteboardItem]?,
        setStringSucceeds: Bool = false,
        writeObjectsSucceeds: Bool = true,
        combinesStrings: Bool = false,
        writeObjectsResults: [Bool] = []
    ) {
        pasteboardItems = items
        self.setStringSucceeds = setStringSucceeds
        self.writeObjectsSucceeds = writeObjectsSucceeds
        self.combinesStrings = combinesStrings
        self.writeObjectsResults = writeObjectsResults
    }

    func clearContents() -> Int {
        clearCount += 1
        changeCount += 1
        pasteboardItems = nil
        return changeCount
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        guard setStringSucceeds else { return false }
        let item = NSPasteboardItem()
        guard item.setString(string, forType: dataType) else { return false }
        pasteboardItems = [item]
        return true
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        if combinesStrings {
            let strings = pasteboardItems?.compactMap {
                $0.string(forType: dataType)
            } ?? []
            return strings.isEmpty ? nil : strings.joined(separator: "\n")
        }
        return pasteboardItems?.first?.string(forType: dataType)
    }

    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        let succeeds = writeObjectsResults.isEmpty
            ? writeObjectsSucceeds
            : writeObjectsResults.removeFirst()
        guard succeeds else { return false }
        pasteboardItems = objects.compactMap { $0 as? NSPasteboardItem }
        return true
    }
}

private final class ReplacingOwnershipPasteboard: PasteboardAccess {
    private var items: [NSPasteboardItem]?
    private var storedChangeCount = 0
    private var replaceNextWrite = true

    init(items: [NSPasteboardItem]) {
        self.items = items
    }

    var pasteboardItems: [NSPasteboardItem]? { items }
    var changeCount: Int { storedChangeCount }

    func clearContents() -> Int {
        storedChangeCount += 1
        items = nil
        return storedChangeCount
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(string, forType: dataType) else { return false }
        items = [item]
        return true
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        items?.first?.string(forType: dataType)
    }

    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        if replaceNextWrite {
            replaceNextWrite = false
            let item = NSPasteboardItem()
            item.setString("newer clipboard", forType: .string)
            items = [item]
            storedChangeCount += 1
        } else {
            items = objects.compactMap { $0 as? NSPasteboardItem }
        }
        return true
    }
}

private final class ChangingBeforeOwnershipPasteboard: PasteboardAccess {
    private enum ConflictState {
        case waitingForSnapshot
        case waitingForSnapshotValidation
        case waitingForOwnershipValidation
        case complete
    }

    private var items: [NSPasteboardItem]?
    private var storedChangeCount = 0
    private var conflictState = ConflictState.waitingForSnapshot

    init(items: [NSPasteboardItem]) {
        self.items = items
    }

    var pasteboardItems: [NSPasteboardItem]? {
        if conflictState == .waitingForSnapshot {
            conflictState = .waitingForSnapshotValidation
        }
        return items
    }

    var changeCount: Int {
        switch conflictState {
        case .waitingForSnapshotValidation:
            conflictState = .waitingForOwnershipValidation
        case .waitingForOwnershipValidation:
            writeNewerClipboard()
            conflictState = .complete
        case .waitingForSnapshot, .complete:
            break
        }
        return storedChangeCount
    }

    func clearContents() -> Int {
        if conflictState == .waitingForOwnershipValidation {
            writeNewerClipboard()
            conflictState = .complete
        }
        storedChangeCount += 1
        items = nil
        return storedChangeCount
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(string, forType: dataType) else { return false }
        items = [item]
        return true
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        items?.first?.string(forType: dataType)
    }

    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        items = objects.compactMap { $0 as? NSPasteboardItem }
        return true
    }

    private func writeNewerClipboard() {
        let item = NSPasteboardItem()
        item.setString("newer clipboard", forType: .string)
        items = [item]
        storedChangeCount += 1
    }
}

private final class ChangingAfterRestorePasteboard: PasteboardAccess {
    private var items: [NSPasteboardItem]?
    private var storedChangeCount = 0
    private var writeCount = 0
    private var replaceBeforeNextCountRead = false

    init(items: [NSPasteboardItem]) {
        self.items = items
    }

    var pasteboardItems: [NSPasteboardItem]? { items }

    var changeCount: Int {
        if replaceBeforeNextCountRead {
            replaceBeforeNextCountRead = false
            let item = NSPasteboardItem()
            item.setString("newer clipboard", forType: .string)
            items = [item]
            storedChangeCount += 1
        }
        return storedChangeCount
    }

    func clearContents() -> Int {
        storedChangeCount += 1
        items = nil
        return storedChangeCount
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(string, forType: dataType) else { return false }
        items = [item]
        return true
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        items?.first?.string(forType: dataType)
    }

    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        writeCount += 1
        items = objects.compactMap { $0 as? NSPasteboardItem }
        if writeCount == 2 {
            replaceBeforeNextCountRead = true
        }
        return true
    }
}

private final class ChangingAfterObservationPasteboard: PasteboardAccess {
    private var items: [NSPasteboardItem]?
    private var storedChangeCount = 0
    private var candidateStringReadCount = 0
    private var armConflictOnNextItemsRead = false
    private var conflictPending = false

    init(items: [NSPasteboardItem]) {
        self.items = items
    }

    var pasteboardItems: [NSPasteboardItem]? {
        if armConflictOnNextItemsRead {
            armConflictOnNextItemsRead = false
            conflictPending = true
        }
        return items
    }

    var changeCount: Int {
        if conflictPending {
            conflictPending = false
            let item = NSPasteboardItem()
            item.setString("newer clipboard", forType: .string)
            items = [item]
            storedChangeCount += 1
        }
        return storedChangeCount
    }

    func clearContents() -> Int {
        storedChangeCount += 1
        items = nil
        return storedChangeCount
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(string, forType: dataType) else { return false }
        items = [item]
        return true
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        let value = items?.first?.string(forType: dataType)
        if value == "Sublime selection" {
            candidateStringReadCount += 1
            if candidateStringReadCount == 2 {
                armConflictOnNextItemsRead = true
            }
        }
        return value
    }

    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        items = objects.compactMap { $0 as? NSPasteboardItem }
        return true
    }
}

/// A tiny reference box for capturing completion results from tests.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}

private struct CapturedPolishRequest: Equatable {
    let baseURL: URL
    let model: String
    let text: String
    let preset: Preset
    let customPrompt: String?
    let apiKey: String
}

private func makeSelectionContext(
    processIdentifier: pid_t,
    selection: SelectionReader.Outcome = .noSelection
) -> SelectionReader.Context {
    let element = AXUIElementCreateApplication(processIdentifier)
    let capture = SelectionReader.capture(
        for: processIdentifier,
        elementResolver: { _ in .resolved(element) },
        processIdentifierReader: { _ in processIdentifier },
        attributeReader: { _, attribute in
            guard attribute as String == kAXSelectedTextAttribute else {
                return (.attributeUnsupported, nil)
            }
            switch selection {
            case .selected(let text):
                return (.success, text as CFString)
            case .clipboardSelection:
                return (.failure, nil)
            case .noSelection:
                return (.success, "" as CFString)
            case .unreadable:
                return (.failure, nil)
            case .clipboardFailure:
                return (.failure, nil)
            }
        }
    )
    guard case .accessibility(let context) = capture else {
        preconditionFailure("Expected an accessibility selection context")
    }
    return context
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
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
        {"choices":[{"message":{"role":"assistant","content":"Polished output"},"finish_reason":"stop"}]}
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

final class SelectionReaderTests: XCTestCase {
    func testUnreadableFocusedTreeWithoutTextRolesUsesClipboardProbe() {
        let window = AXUIElementCreateApplication(101)

        let capture = SelectionReader.capture(
            for: 101,
            elementResolver: { _ in .resolved(window) },
            processIdentifierReader: { _ in 101 },
            attributeReader: { _, attribute in
                switch attribute as String {
                case kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute:
                    return (.attributeUnsupported, nil)
                case kAXRoleAttribute:
                    return (.success, kAXWindowRole as CFString)
                default:
                    return (.attributeUnsupported, nil)
                }
            }
        )

        guard case .clipboardProbe(let context) = capture else {
            return XCTFail("Expected the AX-hostile clipboard fallback")
        }
        XCTAssertEqual(context.processIdentifier, 101)
    }

    func testApplicationCapabilityFindsAccessibleTextRole() {
        let window = AXUIElementCreateApplication(101)
        let textArea = AXUIElementCreateApplication(101)

        let lacksTextSurfaces = SelectionReader.applicationLacksTextSurfaces(
            for: 101,
            processIdentifierReader: { _ in 101 },
            attributeReader: { element, attribute in
                switch attribute as String {
                case kAXRoleAttribute:
                    return (
                        .success,
                        (CFEqual(element, textArea) ? kAXTextAreaRole : kAXWindowRole) as CFString
                    )
                default:
                    return (.attributeUnsupported, nil)
                }
            },
            childrenReader: { element in
                CFEqual(element, window) ? (.success, [textArea]) : (.success, [])
            },
            applicationElement: { _ in window }
        )

        XCTAssertFalse(lacksTextSurfaces)
    }

    func testApplicationCapabilityFindsTextSurfaceOutsideFocusedSubtree() {
        let application = AXUIElementCreateApplication(101)
        let textArea = AXUIElementCreateApplication(202)

        let lacksTextSurfaces = SelectionReader.applicationLacksTextSurfaces(
            for: 101,
            processIdentifierReader: { _ in 101 },
            attributeReader: { element, attribute in
                switch attribute as String {
                case kAXRoleAttribute:
                    if CFEqual(element, application) {
                        return (.success, kAXApplicationRole as CFString)
                    }
                    return (
                        .success,
                        (CFEqual(element, textArea) ? kAXTextAreaRole : kAXButtonRole) as CFString
                    )
                default:
                    return (.attributeUnsupported, nil)
                }
            },
            childrenReader: { element in
                CFEqual(element, application) ? (.success, [textArea]) : (.success, [])
            },
            applicationElement: { _ in application }
        )

        XCTAssertFalse(lacksTextSurfaces)
    }

    func testApplicationWithoutTextSurfacesPassesCapabilityCheck() {
        let application = AXUIElementCreateApplication(101)

        let lacksTextSurfaces = SelectionReader.applicationLacksTextSurfaces(
            for: 101,
            processIdentifierReader: { _ in 101 },
            attributeReader: { _, attribute in
                attribute as String == kAXRoleAttribute
                    ? (.success, kAXWindowRole as CFString)
                    : (.attributeUnsupported, nil)
            },
            childrenReader: { _ in (.success, []) },
            applicationElement: { _ in application }
        )

        XCTAssertTrue(lacksTextSurfaces)
    }

    func testMenuBarOnlyTreeBeyondWalkCapProvesLackOfTextSurfaces() {
        // Sublime-shape tree: the application element exposes only a menu bar,
        // and the menu subtree alone would exceed the 512-element walk cap if
        // the walk descended into it.
        let application = AXUIElementCreateApplication(101)
        let menuBar = AXUIElementCreateApplication(202)
        let menu = AXUIElementCreateApplication(203)
        let menuItem = AXUIElementCreateApplication(204)
        var menuChildrenReads = 0

        let lacksTextSurfaces = SelectionReader.applicationLacksTextSurfaces(
            for: 101,
            processIdentifierReader: { _ in 101 },
            attributeReader: { element, attribute in
                guard attribute as String == kAXRoleAttribute else {
                    return (.attributeUnsupported, nil)
                }
                if CFEqual(element, application) {
                    return (.success, kAXApplicationRole as CFString)
                }
                if CFEqual(element, menuBar) {
                    return (.success, kAXMenuBarRole as CFString)
                }
                if CFEqual(element, menu) {
                    return (.success, kAXMenuRole as CFString)
                }
                return (.success, kAXMenuItemRole as CFString)
            },
            childrenReader: { element in
                if CFEqual(element, application) {
                    return (.success, [menuBar])
                }
                if CFEqual(element, menuBar) {
                    return (.success, [menu])
                }
                if CFEqual(element, menu) {
                    menuChildrenReads += 1
                    return (.success, Array(repeating: menuItem, count: 64))
                }
                return (.success, [])
            },
            applicationElement: { _ in application }
        )

        XCTAssertTrue(lacksTextSurfaces)
        XCTAssertEqual(menuChildrenReads, 0)
    }

    func testContentTreeWithoutTextRolesBesideMenuBarProvesLackOfTextSurfaces() {
        let application = AXUIElementCreateApplication(101)
        let menuBar = AXUIElementCreateApplication(202)
        let menu = AXUIElementCreateApplication(203)
        let content = AXUIElementCreateApplication(204)
        let contentChild = AXUIElementCreateApplication(205)

        let lacksTextSurfaces = SelectionReader.applicationLacksTextSurfaces(
            for: 101,
            processIdentifierReader: { _ in 101 },
            attributeReader: { element, attribute in
                guard attribute as String == kAXRoleAttribute else {
                    return (.attributeUnsupported, nil)
                }
                if CFEqual(element, menuBar) {
                    return (.success, kAXMenuBarRole as CFString)
                }
                if CFEqual(element, menu) {
                    return (.success, kAXMenuRole as CFString)
                }
                return (.success, kAXGroupRole as CFString)
            },
            childrenReader: { element in
                if CFEqual(element, application) {
                    return (.success, [menuBar, content])
                }
                if CFEqual(element, menuBar) {
                    return (.success, [menu])
                }
                if CFEqual(element, content) {
                    return (.success, [contentChild])
                }
                return (.success, [])
            },
            applicationElement: { _ in application }
        )

        XCTAssertTrue(lacksTextSurfaces)
    }

    func testUnreadableContentNodeOutsideMenuBarStillFailsClosed() {
        let application = AXUIElementCreateApplication(101)
        let menuBar = AXUIElementCreateApplication(202)
        let content = AXUIElementCreateApplication(203)

        let lacksTextSurfaces = SelectionReader.applicationLacksTextSurfaces(
            for: 101,
            processIdentifierReader: { _ in 101 },
            attributeReader: { element, attribute in
                guard attribute as String == kAXRoleAttribute else {
                    return (.attributeUnsupported, nil)
                }
                if CFEqual(element, content) {
                    return (.cannotComplete, nil)
                }
                if CFEqual(element, menuBar) {
                    return (.success, kAXMenuBarRole as CFString)
                }
                return (.success, kAXApplicationRole as CFString)
            },
            childrenReader: { element in
                if CFEqual(element, application) {
                    return (.success, [menuBar, content])
                }
                return (.success, [])
            },
            applicationElement: { _ in application }
        )

        XCTAssertFalse(lacksTextSurfaces)
    }

    func testReadableEmptyAXSelectionDoesNotUseClipboardProbe() {
        let textArea = AXUIElementCreateApplication(101)

        let capture = SelectionReader.capture(
            for: 101,
            elementResolver: { _ in .resolved(textArea) },
            processIdentifierReader: { _ in 101 },
            attributeReader: { _, attribute in
                switch attribute as String {
                case kAXSelectedTextAttribute:
                    return (.success, "" as CFString)
                case kAXRoleAttribute:
                    return (.success, kAXTextAreaRole as CFString)
                default:
                    return (.attributeUnsupported, nil)
                }
            }
        )

        guard case .accessibility(let context) = capture else {
            return XCTFail("A readable empty AX selection must stay on the native path")
        }
        XCTAssertEqual(context.selection, .noSelection)
    }

    func testSliceExtractsSelectedRange() {
        let outcome: SelectionReader.Outcome = .selected("brave")
        XCTAssertEqual(
            SelectionReader.slice("hello brave new world", CFRange(location: 6, length: 5)),
            outcome
        )
    }

    func testOnlyTransientContextErrorsAreRetried() {
        XCTAssertTrue(SelectionReader.isRetriable(.cannotComplete))
        XCTAssertTrue(SelectionReader.isRetriable(.invalidUIElement))
        XCTAssertFalse(SelectionReader.isRetriable(.failure))
        XCTAssertFalse(SelectionReader.isRetriable(.apiDisabled))
        XCTAssertFalse(SelectionReader.isRetriable(.attributeUnsupported))
        XCTAssertFalse(SelectionReader.isRetriable(.noValue))
        XCTAssertFalse(SelectionReader.isRetriable(.success))
    }

    func testSliceEmptyRangeReportsNoSelection() {
        let outcome: SelectionReader.Outcome = .noSelection
        XCTAssertEqual(
            SelectionReader.slice("hello", CFRange(location: 0, length: 0)),
            outcome
        )
    }

    func testSliceOutOfRangeRangeReportsUnreadable() {
        let outcome: SelectionReader.Outcome = .unreadable
        XCTAssertEqual(
            SelectionReader.slice("hello", CFRange(location: 3, length: 100)),
            outcome
        )
    }

    func testTransientSelectedRangeFailureRetriesFallback() {
        var range = CFRange(location: 6, length: 5)
        let rangeValue = AXValueCreate(.cfRange, &range)!
        var rangeAttempts = 0
        let element = AXUIElementCreateSystemWide()

        let outcome = SelectionReader.readSelection(
            from: context(for: element, selection: .selected("brave")),
            elementResolver: { _ in .resolved(element) },
            attributeReader: { _, attribute in
                switch attribute as String {
                case kAXSelectedTextAttribute:
                    return (.attributeUnsupported, nil)
                case kAXSelectedTextRangeAttribute:
                    rangeAttempts += 1
                    return rangeAttempts == 1
                        ? (.cannotComplete, nil)
                        : (.success, rangeValue)
                case kAXValueAttribute:
                    return (.success, "hello brave new world" as CFString)
                default:
                    return (.attributeUnsupported, nil)
                }
            },
            sleep: { _ in }
        )

        XCTAssertEqual(outcome, .selected("brave"))
        XCTAssertEqual(rangeAttempts, 2)
    }

    func testTransientValueFailureRetriesFallback() {
        var range = CFRange(location: 6, length: 5)
        let rangeValue = AXValueCreate(.cfRange, &range)!
        var valueAttempts = 0
        let element = AXUIElementCreateSystemWide()

        let outcome = SelectionReader.readSelection(
            from: context(for: element, selection: .selected("brave")),
            elementResolver: { _ in .resolved(element) },
            attributeReader: { _, attribute in
                switch attribute as String {
                case kAXSelectedTextAttribute:
                    return (.noValue, nil)
                case kAXSelectedTextRangeAttribute:
                    return (.success, rangeValue)
                case kAXValueAttribute:
                    valueAttempts += 1
                    return valueAttempts == 1
                        ? (.cannotComplete, nil)
                        : (.success, "hello brave new world" as CFString)
                default:
                    return (.attributeUnsupported, nil)
                }
            },
            sleep: { _ in }
        )

        XCTAssertEqual(outcome, .selected("brave"))
        XCTAssertEqual(valueAttempts, 2)
    }

    func testUnsupportedRangeReportsUnreadable() {
        let element = AXUIElementCreateSystemWide()

        let outcome = SelectionReader.readSelection(
            from: context(for: element),
            elementResolver: { _ in .resolved(element) },
            attributeReader: { _, attribute in
                switch attribute as String {
                case kAXSelectedTextAttribute:
                    return (.attributeUnsupported, nil)
                case kAXSelectedTextRangeAttribute:
                    return (.attributeUnsupported, nil)
                default:
                    return (.success, nil)
                }
            },
            sleep: { _ in }
        )

        XCTAssertEqual(outcome, .unreadable)
    }

    func testUnavailableValueForNonemptyRangeReportsUnreadable() {
        var range = CFRange(location: 6, length: 5)
        let rangeValue = AXValueCreate(.cfRange, &range)!
        let element = AXUIElementCreateSystemWide()

        let outcome = SelectionReader.readSelection(
            from: context(for: element),
            elementResolver: { _ in .resolved(element) },
            attributeReader: { _, attribute in
                switch attribute as String {
                case kAXSelectedTextAttribute:
                    return (.noValue, nil)
                case kAXSelectedTextRangeAttribute:
                    return (.success, rangeValue)
                case kAXValueAttribute:
                    return (.noValue, nil)
                default:
                    return (.success, nil)
                }
            },
            sleep: { _ in }
        )

        XCTAssertEqual(outcome, .unreadable)
    }

    func testMalformedSelectedRangeReportsUnreadable() {
        let element = AXUIElementCreateSystemWide()

        let outcome = SelectionReader.readSelection(
            from: context(for: element),
            elementResolver: { _ in .resolved(element) },
            attributeReader: { _, attribute in
                switch attribute as String {
                case kAXSelectedTextAttribute:
                    return (.noValue, nil)
                case kAXSelectedTextRangeAttribute:
                    return (.success, "not a range" as CFString)
                default:
                    return (.success, nil)
                }
            },
            sleep: { _ in }
        )

        XCTAssertEqual(outcome, .unreadable)
    }

    func testSelectionChangeBeforeReadReturnsUnreadable() {
        let element = AXUIElementCreateApplication(101)
        let context = context(for: element, selection: .selected("original selection"))

        let outcome = SelectionReader.readSelection(
            from: context,
            elementResolver: { _ in .resolved(element) },
            attributeReader: attributeReader(for: .selected("replacement selection")),
            sleep: { _ in }
        )

        XCTAssertEqual(outcome, .unreadable)
    }

    func testSelectionChangeDuringRetryReturnsUnreadable() {
        let element = AXUIElementCreateApplication(101)
        let context = context(for: element, selection: .selected("original selection"))
        var readAttempts = 0
        var currentSelection = "original selection"

        let outcome = SelectionReader.readSelection(
            from: context,
            elementResolver: { _ in .resolved(element) },
            attributeReader: { _, attribute in
                guard attribute as String == kAXSelectedTextAttribute else {
                    return (.attributeUnsupported, nil)
                }
                readAttempts += 1
                return readAttempts == 1
                    ? (.cannotComplete, nil)
                    : (.success, currentSelection as CFString)
            },
            sleep: { _ in currentSelection = "replacement selection" }
        )

        XCTAssertEqual(outcome, .unreadable)
        XCTAssertEqual(readAttempts, 2)
    }

    func testCaptureFailsClosedOnTransientResolutionFailure() {
        let element = AXUIElementCreateApplication(101)
        var resolutionAttempts = 0

        let capture = SelectionReader.capture(
            for: 101,
            elementResolver: { _ in
                resolutionAttempts += 1
                return resolutionAttempts == 1
                    ? .failed(.cannotComplete)
                    : .resolved(element)
            },
            processIdentifierReader: { _ in 101 },
            attributeReader: attributeReader(for: .selected("selection"))
        )

        guard case .unavailable = capture else {
            return XCTFail("Expected capture to fail closed")
        }
        XCTAssertEqual(resolutionAttempts, 1)
    }

    func testCaptureFailsClosedOnTransientSelectionRead() {
        let element = AXUIElementCreateApplication(101)
        var readAttempts = 0

        let capture = SelectionReader.capture(
            for: 101,
            elementResolver: { _ in .resolved(element) },
            processIdentifierReader: { _ in 101 },
            attributeReader: { _, attribute in
                guard attribute as String == kAXSelectedTextAttribute else {
                    return (.attributeUnsupported, nil)
                }
                readAttempts += 1
                return readAttempts == 1
                    ? (.cannotComplete, nil)
                    : (.success, "replacement selection" as CFString)
            }
        )

        guard case .unavailable = capture else {
            return XCTFail("Expected capture to fail closed")
        }
        XCTAssertEqual(readAttempts, 1)
    }

    func testReadRetriesTransientResolutionFailure() {
        let element = AXUIElementCreateApplication(101)
        let context = context(for: element, selection: .selected("selection"))
        var resolutionAttempts = 0

        let outcome = SelectionReader.readSelection(
            from: context,
            elementResolver: { _ in
                resolutionAttempts += 1
                return resolutionAttempts == 1
                    ? .failed(.cannotComplete)
                    : .resolved(element)
            },
            attributeReader: attributeReader(for: .selected("selection")),
            sleep: { _ in }
        )

        XCTAssertEqual(outcome, .selected("selection"))
        XCTAssertEqual(resolutionAttempts, 2)
    }

    func testFocusChangeBeforeReadReturnsUnreadable() throws {
        let originalElement = AXUIElementCreateApplication(101)
        let replacementElement = AXUIElementCreateApplication(202)
        var focusedElement = originalElement
        var resolutionCount = 0
        let resolveFocusedElement: (pid_t) -> SelectionReader.ElementResolution = { _ in
            resolutionCount += 1
            return .resolved(focusedElement)
        }
        let capture = SelectionReader.capture(
            for: 101,
            elementResolver: resolveFocusedElement,
            processIdentifierReader: { _ in 101 },
            attributeReader: attributeReader(for: .selected("selection"))
        )
        guard case .accessibility(let context) = capture else {
            return XCTFail("Expected an accessibility selection context")
        }
        focusedElement = replacementElement
        var readAttempts = 0

        let outcome = SelectionReader.readSelection(
            from: context,
            elementResolver: resolveFocusedElement,
            attributeReader: { _, attribute in
                guard attribute as String == kAXSelectedTextAttribute else {
                    return (.attributeUnsupported, nil)
                }
                readAttempts += 1
                return (.success, "selection" as CFString)
            },
            sleep: { _ in }
        )

        XCTAssertEqual(outcome, .unreadable)
        XCTAssertEqual(resolutionCount, 2)
        XCTAssertEqual(readAttempts, 0)
    }

    func testFocusChangeDuringRetryReturnsUnreadable() throws {
        let originalElement = AXUIElementCreateApplication(101)
        let replacementElement = AXUIElementCreateApplication(202)
        var focusedElement = originalElement
        var resolutionCount = 0
        let resolveFocusedElement: (pid_t) -> SelectionReader.ElementResolution = { _ in
            resolutionCount += 1
            return .resolved(focusedElement)
        }
        let capture = SelectionReader.capture(
            for: 101,
            elementResolver: resolveFocusedElement,
            processIdentifierReader: { _ in 101 },
            attributeReader: attributeReader(for: .selected("selection"))
        )
        guard case .accessibility(let context) = capture else {
            return XCTFail("Expected an accessibility selection context")
        }
        var readAttempts = 0

        let outcome = SelectionReader.readSelection(
            from: context,
            elementResolver: resolveFocusedElement,
            attributeReader: { _, attribute in
                guard attribute as String == kAXSelectedTextAttribute else {
                    return (.attributeUnsupported, nil)
                }
                readAttempts += 1
                return (.cannotComplete, nil)
            },
            sleep: { _ in focusedElement = replacementElement }
        )

        XCTAssertEqual(outcome, .unreadable)
        XCTAssertEqual(resolutionCount, 3)
        XCTAssertEqual(readAttempts, 1)
    }

    func testInvalidCapturedElementReturnsUnreadable() throws {
        let staleElement = AXUIElementCreateApplication(101)
        var resolutionCount = 0
        let resolveFocusedElement: (pid_t) -> SelectionReader.ElementResolution = { _ in
            resolutionCount += 1
            return .resolved(staleElement)
        }
        let capture = SelectionReader.capture(
            for: 101,
            elementResolver: resolveFocusedElement,
            processIdentifierReader: { _ in 101 },
            attributeReader: attributeReader(for: .selected("selection"))
        )
        guard case .accessibility(let context) = capture else {
            return XCTFail("Expected an accessibility selection context")
        }
        var invalidAttempts = 0

        let outcome = SelectionReader.readSelection(
            from: context,
            elementResolver: resolveFocusedElement,
            attributeReader: { _, attribute in
                guard attribute as String == kAXSelectedTextAttribute else {
                    return (.attributeUnsupported, nil)
                }
                invalidAttempts += 1
                return (.invalidUIElement, nil)
            },
            sleep: { _ in }
        )

        XCTAssertEqual(outcome, .unreadable)
        XCTAssertEqual(resolutionCount, 4)
        XCTAssertEqual(invalidAttempts, 3)
    }

    func testCaptureRejectsElementFromDifferentProcess() {
        let foreignElement = AXUIElementCreateApplication(202)

        let capture = SelectionReader.capture(
            for: 101,
            elementResolver: { _ in .resolved(foreignElement) },
            processIdentifierReader: { _ in 202 },
            attributeReader: attributeReader(for: .selected("selection"))
        )

        guard case .unavailable = capture else {
            return XCTFail("Expected capture to reject the foreign element")
        }
    }

    func testDirectFocusedElementFromDifferentProcessUsesConstrainedFallback() throws {
        let targetProcessIdentifier: pid_t = 101
        let application = AXUIElementCreateApplication(targetProcessIdentifier)
        let systemWide = AXUIElementCreateSystemWide()
        let foreignElement = AXUIElementCreateApplication(202)
        let targetElement = AXUIElementCreateApplication(targetProcessIdentifier)

        let resolved = SelectionReader.resolveFocusedElement(
            for: targetProcessIdentifier,
            applicationElement: { _ in application },
            systemWideElement: { systemWide },
            attributeReader: { owner, _ in
                CFEqual(owner, application)
                    ? (.success, foreignElement)
                    : (.success, targetElement)
            },
            processIdentifierReader: { element in
                CFEqual(element, foreignElement) ? 202 : targetProcessIdentifier
            }
        )

        guard case .resolved(let element) = resolved else {
            return XCTFail("Expected the PID-constrained fallback element")
        }
        XCTAssertTrue(CFEqual(element, targetElement))
    }

    func testFocusedElementResolutionPreservesRetriableError() {
        let targetProcessIdentifier: pid_t = 101
        let application = AXUIElementCreateApplication(targetProcessIdentifier)
        let systemWide = AXUIElementCreateSystemWide()
        let foreignElement = AXUIElementCreateApplication(202)

        let resolved = SelectionReader.resolveFocusedElement(
            for: targetProcessIdentifier,
            applicationElement: { _ in application },
            systemWideElement: { systemWide },
            attributeReader: { owner, _ in
                CFEqual(owner, application)
                    ? (.cannotComplete, nil)
                    : (.success, foreignElement)
            },
            processIdentifierReader: { _ in 202 }
        )

        guard case .failed(let error) = resolved else {
            return XCTFail("Expected focused-element resolution to fail")
        }
        XCTAssertEqual(error, .cannotComplete)
    }

    private func context(
        for element: AXUIElement,
        selection: SelectionReader.Outcome = .noSelection
    ) -> SelectionReader.Context {
        let capture = SelectionReader.capture(
            for: 101,
            elementResolver: { _ in .resolved(element) },
            processIdentifierReader: { _ in 101 },
            attributeReader: attributeReader(for: selection)
        )
        guard case .accessibility(let context) = capture else {
            preconditionFailure("Expected an accessibility selection context")
        }
        return context
    }

    private func attributeReader(
        for selection: SelectionReader.Outcome
    ) -> SelectionReader.AttributeReader {
        { _, attribute in
            guard attribute as String == kAXSelectedTextAttribute else {
                return (.attributeUnsupported, nil)
            }
            switch selection {
            case .selected(let text):
                return (.success, text as CFString)
            case .clipboardSelection:
                return (.failure, nil)
            case .noSelection:
                return (.success, "" as CFString)
            case .unreadable:
                return (.failure, nil)
            case .clipboardFailure:
                return (.failure, nil)
            }
        }
    }
}
