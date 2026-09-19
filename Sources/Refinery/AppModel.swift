import AppKit
import Combine
import SwiftUI

/// Application state: settings, preset selection, hotkey handling and the
/// polish pipeline (selection -> endpoint -> clipboard).
@MainActor
public final class AppModel: ObservableObject {
    // MARK: Published state
    @Published var settings: AppSettings
    @Published var lastOutcome: Outcome?
    @Published var isRunning = false
    @Published private(set) var settingsAreReadable: Bool

    enum Outcome: Equatable {
        case polished
        case emptySelection
        case hotkeyRegistrationFailure
        case failure(String)
    }

    private let hotkeyCenter: any HotkeyManaging
    private let persistSettings: (AppSettings) -> Void
    private let accessibilityEnabled: () -> Bool
    private let accessibilityPrompt: () -> Void
    private let frontmostApplicationPID: () -> pid_t?
    private let captureSelection: (pid_t) -> SelectionReader.Capture
    private let readSelection: @Sendable (SelectionReader.Context) -> SelectionReader.Outcome
    private let probeClipboardSelection: @MainActor @Sendable (
        SelectionReader.ClipboardContext,
        ClipboardSelectionProbe.OwnershipHandler
    ) async -> SelectionReader.Outcome
    private let readAPIKey: (URL) throws -> String?
    private let polish: @Sendable (URL, String, String, Preset, String?, String) async throws -> String
    private let writeClipboard: (String, Int?) -> Result<Void, ClipboardError>
    private var isClipboardOwnershipActive = false
    private var pendingTerminationReply: ((Bool) -> Void)?

    private enum APIKeySnapshot: Sendable {
        case available(String)
        case missing
        case failure(String)
    }

    private struct RequestConfiguration: Sendable {
        let baseURL: URL?
        let model: String
        let preset: Preset
        let apiKey: APIKeySnapshot?
    }

    /// Exposes hotkey wiring to the app delegate.
    public func setTrigger(_ handler: @escaping () -> Void) {
        hotkeyCenter.onTrigger = handler
    }

    public convenience init() {
        let settings: AppSettings
        let settingsAreReadable: Bool
        do {
            settings = try AppSettings.load()
            settingsAreReadable = true
        } catch {
            settings = AppSettings(baseURL: "", model: "")
            settingsAreReadable = false
        }
        self.init(
            settings: settings,
            settingsAreReadable: settingsAreReadable,
            hotkeyCenter: HotkeyCenter()
        )
    }

    init(
        settings: AppSettings,
        settingsAreReadable: Bool = true,
        hotkeyCenter: any HotkeyManaging,
        persistSettings: @escaping (AppSettings) -> Void = { $0.save() },
        accessibilityEnabled: @escaping () -> Bool = SelectionReader.isAccessibilityEnabled,
        accessibilityPrompt: @escaping () -> Void = SelectionReader.promptForAccessibility,
        frontmostApplicationPID: @escaping () -> pid_t? = SelectionReader.frontmostApplicationPID,
        captureSelection: @escaping (pid_t) -> SelectionReader.Capture = SelectionReader.capture,
        readSelection: @escaping @Sendable (SelectionReader.Context) -> SelectionReader.Outcome = {
            SelectionReader.readSelection(from: $0)
        },
        probeClipboardSelection: @escaping @MainActor @Sendable (
            SelectionReader.ClipboardContext,
            ClipboardSelectionProbe.OwnershipHandler
        ) async -> SelectionReader.Outcome = {
            await ClipboardSelectionProbe.read(
                for: $0,
                ownershipChanged: $1
            )
        },
        readAPIKey: @escaping (URL) throws -> String? = { try KeychainStore.readAPIKey(for: $0) },
        polish: @escaping @Sendable (
            URL,
            String,
            String,
            Preset,
            String?,
            String
        ) async throws -> String = { baseURL, model, text, preset, custom, key in
            let client = EndpointClient(baseURL: baseURL, model: model)
            return try await client.polish(text, preset: preset, customPrompt: custom, apiKey: key)
        },
        writeClipboard: @escaping (String, Int?) -> Result<Void, ClipboardError> = {
            ClipboardStore.writeResult(
                $0,
                to: NSPasteboard.general,
                ifUnchangedSince: $1
            )
        }
    ) {
        self.settings = settings
        self.settingsAreReadable = settingsAreReadable
        self.hotkeyCenter = hotkeyCenter
        self.persistSettings = persistSettings
        self.accessibilityEnabled = accessibilityEnabled
        self.accessibilityPrompt = accessibilityPrompt
        self.frontmostApplicationPID = frontmostApplicationPID
        self.captureSelection = captureSelection
        self.readSelection = readSelection
        self.probeClipboardSelection = probeClipboardSelection
        self.readAPIKey = readAPIKey
        self.polish = polish
        self.writeClipboard = writeClipboard
        applyHotkey()
    }

    // MARK: Settings
    func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        if settingsAreReadable {
            persistSettings(settings)
        }
    }

    @discardableResult
    func updateEndpoint(baseURL: String, model: String) -> Bool {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedBaseURL),
              EndpointClient.isAllowedBaseURL(url),
              !trimmedModel.isEmpty else {
            lastOutcome = .failure(EndpointError.invalidBaseURL.localizedDescription)
            return false
        }
        settings.baseURL = trimmedBaseURL
        settings.model = trimmedModel
        settingsAreReadable = true
        persistSettings(settings)
        lastOutcome = nil
        return true
    }

    var baseURL: URL? {
        let trimmed = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed)
    }

    // MARK: Hotkey
    func applyHotkey() {
        let ok = hotkeyCenter.register(
            keyCode: UInt32(settings.hotkeyKeyCode),
            modifiers: UInt32(settings.hotkeyModifiers)
        )
        if !ok {
            lastOutcome = .hotkeyRegistrationFailure
        }
    }

    func suspendHotkey() {
        hotkeyCenter.suspend()
    }

    func resumeHotkey() {
        hotkeyCenter.resume()
    }

    public func cancelHotkeyRecording() {
        HotkeyRecorder.cancel()
        hotkeyCenter.resume()
    }

    /// AppKit termination gate while the clipboard probe owns the
    /// pasteboard: defers termination (terminateLater) until the probe
    /// restores the snapshot, then replies `true` to continue quitting.
    /// Returns false when no probe is active, so termination proceeds now.
    /// A failed restore replies `false`, cancelling the quit. Only the first
    /// registered reply is kept; a request arriving while one is pending is
    /// answered by that existing reply.
    public func deferTerminationUntilClipboardRestored(
        _ reply: @escaping (Bool) -> Void
    ) -> Bool {
        guard isClipboardOwnershipActive else { return false }
        guard pendingTerminationReply == nil else { return true }
        pendingTerminationReply = reply
        return true
    }

    /// Registers a newly recorded hotkey, keeping the previous registration
    /// and persisted settings when the new combination cannot be registered.
    @discardableResult
    func adoptHotkey(keyCode: Int, modifiers: Int) -> Bool {
        let ok = hotkeyCenter.register(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
        if ok {
            update {
                $0.hotkeyKeyCode = keyCode
                $0.hotkeyModifiers = modifiers
            }
            if lastOutcome == .hotkeyRegistrationFailure {
                lastOutcome = nil
            }
        } else {
            lastOutcome = .hotkeyRegistrationFailure
        }
        return ok
    }

    // MARK: The pipeline
    public func handleHotkey() {
        guard !isRunning, NSApp.modalWindow == nil else { return }

        let processIdentifier = frontmostApplicationPID()
        let requestBaseURL = baseURL
        let requestModel = settings.model
        let requestPreset = settings.preset

        guard settingsAreReadable else {
            lastOutcome = .failure("Settings are unreadable. Re-open Refinery settings to reconfigure the endpoint.")
            return
        }

        guard accessibilityEnabled() else {
            lastOutcome = .failure("Accessibility permission is required to read the selected text.")
            accessibilityPrompt()
            return
        }

        guard let processIdentifier else {
            lastOutcome = .failure(
                "Could not read the selection from the frontmost app. Try again in a moment."
            )
            return
        }

        let selectionCapture = captureSelection(processIdentifier)
        if case .unavailable = selectionCapture {
            lastOutcome = .failure(
                "Could not read the selection from the frontmost app. Try again in a moment."
            )
            return
        }

        let apiKey: APIKeySnapshot?
        if let url = requestBaseURL, EndpointClient.isAllowedBaseURL(url) {
            do {
                if let savedKey = try readAPIKey(url) {
                    apiKey = .available(savedKey)
                } else {
                    apiKey = .missing
                }
            } catch {
                apiKey = .failure(error.localizedDescription)
            }
        } else {
            apiKey = nil
        }
        let configuration = RequestConfiguration(
            baseURL: requestBaseURL,
            model: requestModel,
            preset: requestPreset,
            apiKey: apiKey
        )

        isRunning = true
        let readSelection = self.readSelection
        let probeClipboardSelection = self.probeClipboardSelection
        Task { [weak self] in
            let selection: SelectionReader.Outcome
            switch selectionCapture {
            case .accessibility(let context):
                selection = await Task.detached(priority: .userInitiated) {
                    readSelection(context)
                }.value
            case .clipboardProbe(let context):
                selection = await probeClipboardSelection(context) { [weak self] event in
                    self?.handleClipboardOwnership(event)
                }
            case .unavailable:
                selection = .unreadable
            }
            self?.handle(selection: selection, configuration: configuration)
        }
    }

    private func handleClipboardOwnership(
        _ event: ClipboardSelectionProbe.OwnershipEvent
    ) {
        switch event {
        case .began:
            isClipboardOwnershipActive = true
        case .endedSafely:
            isClipboardOwnershipActive = false
            let reply = pendingTerminationReply
            pendingTerminationReply = nil
            reply?(true)
        case .restorationFailed:
            isClipboardOwnershipActive = false
            let reply = pendingTerminationReply
            pendingTerminationReply = nil
            reply?(false)
        }
    }

    private func handle(
        selection: SelectionReader.Outcome,
        configuration: RequestConfiguration
    ) {
        let selected: String
        let expectedClipboardChangeCount: Int?
        switch selection {
        case .selected(let text):
            selected = text
            expectedClipboardChangeCount = nil
        case .clipboardSelection(let text, let expectedChangeCount):
            selected = text
            expectedClipboardChangeCount = expectedChangeCount
        case .noSelection:
            lastOutcome = .emptySelection
            isRunning = false
            return
        case .unreadable:
            lastOutcome = .failure(
                "Could not read the selection from the frontmost app. Try again in a moment."
            )
            isRunning = false
            return
        case .clipboardFailure(let error):
            lastOutcome = .failure(error.localizedDescription)
            isRunning = false
            return
        }

        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastOutcome = .emptySelection
            isRunning = false
            return
        }

        guard let url = configuration.baseURL, EndpointClient.isAllowedBaseURL(url) else {
            lastOutcome = .failure(EndpointError.invalidBaseURL.localizedDescription)
            isRunning = false
            return
        }

        guard let apiKeySnapshot = configuration.apiKey else {
            lastOutcome = .failure(EndpointError.missingAPIKey.localizedDescription)
            isRunning = false
            return
        }
        let key: String
        switch apiKeySnapshot {
        case .available(let savedKey):
            key = savedKey
        case .missing:
            lastOutcome = .failure(EndpointError.missingAPIKey.localizedDescription)
            isRunning = false
            return
        case .failure(let message):
            lastOutcome = .failure(message)
            isRunning = false
            return
        }

        // Custom preset requires a typed prompt; the panel returns nil when cancelled.
        var customPrompt: String?
        if configuration.preset == .customOneOff {
            guard let typed = CustomPromptPanel.prompt() else {
                isRunning = false
                return
            }
            customPrompt = typed
        }

        let selectedText = selected
        let custom = customPrompt
        let apiKey = key
        let expectedChangeCount = expectedClipboardChangeCount
        Task { @MainActor in
            do {
                let result = try await polish(
                    url,
                    configuration.model,
                    selectedText,
                    configuration.preset,
                    custom,
                    apiKey
                )
                switch writeClipboard(result, expectedChangeCount) {
                case .success:
                    break
                case .failure(let error):
                    throw error
                }
                lastOutcome = .polished
                isRunning = false
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                lastOutcome = .failure(message)
                isRunning = false
            }
        }
    }
}
