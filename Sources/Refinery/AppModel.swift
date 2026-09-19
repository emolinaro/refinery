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
    private let fetchSubscriptionCredential: @Sendable () async throws -> ChatGPTSession.Credential
    private let polish: @Sendable (URL, String, String, Preset, String?, String) async throws -> String
    private let polishViaSubscription: @Sendable (String, Preset, String?, ChatGPTSession.Credential) async throws -> String
    private let writeClipboard: (String, Int?) -> Result<Void, ClipboardError>
    private var isClipboardOwnershipActive = false
    private var pendingTerminationReply: ((Bool) -> Void)?

    /// The provider that served the most recent polish, for the dropdown.
    @Published private(set) var lastPolishProvider: ProviderSelection?

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
        var subscriptionCredential: ChatGPTSession.Credential?
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
        fetchSubscriptionCredential: @Sendable @escaping () async throws -> ChatGPTSession.Credential = {
            try await ChatGPTSession().validCredential().credential
        },
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
        polishViaSubscription: @escaping @Sendable (
            String,
            Preset,
            String?,
            ChatGPTSession.Credential
        ) async throws -> String = { text, preset, custom, credential in
            let client = SubscriptionClient()
            return try await client.polish(text, preset: preset, customPrompt: custom, credential: credential)
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
        self.fetchSubscriptionCredential = fetchSubscriptionCredential
        self.polish = polish
        self.polishViaSubscription = polishViaSubscription
        self.writeClipboard = writeClipboard
        self.accountController = SubscriptionAccountController()
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

    // MARK: Provider

    /// The provider serving polish requests under current settings, or nil
    /// when none is usable.
    var activeProvider: ProviderSelection? {
        PolishService(settings: settings).activeProvider
    }

    /// Selects the provider, persisting immediately.
    func select(provider: ProviderSelection) {
        update { $0.provider = provider }
        if provider == .openAISubscription {
            subscriptionAccount.refreshAccountState()
        }
    }

    /// The non-secret account state shown in Settings and the dropdown.
    var subscriptionAccount: SubscriptionAccountController { accountController }

    /// The subscription account controller, injected by tests.
    private let accountController: SubscriptionAccountController

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
        let requestProvider = settings.provider

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
        if requestProvider == .openAICompatibleEndpoint,
           let url = requestBaseURL, EndpointClient.isAllowedBaseURL(url) {
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
            apiKey: apiKey,
            subscriptionCredential: nil
        )

        isRunning = true
        let readSelection = self.readSelection
        let probeClipboardSelection = self.probeClipboardSelection
        let fetchSubscriptionCredential: @Sendable () async throws -> ChatGPTSession.Credential = { [fetchSubscriptionCredential] in
            try await fetchSubscriptionCredential()
        }
        let polish = self.polish
        let polishViaSubscription = self.polishViaSubscription
        Task { [weak self] in
            // Fetch the subscription credential (refreshing if needed)
            // concurrently with reading the selection.
            async let subscriptionCredential = requestProvider == .openAISubscription
                ? fetchSubscriptionCredential()
                : nil
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
            let fetchedSubscriptionCredential: ChatGPTSession.Credential?
            do {
                fetchedSubscriptionCredential = try await subscriptionCredential
            } catch {
                fetchedSubscriptionCredential = nil
                await MainActor.run {
                    self?.lastOutcome = .failure(
                        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    )
                    self?.isRunning = false
                }
                return
            }
            var mutableConfiguration = configuration
            mutableConfiguration.subscriptionCredential = fetchedSubscriptionCredential
            self?.handle(
                selection: selection,
                configuration: mutableConfiguration,
                polish: polish,
                polishViaSubscription: polishViaSubscription
            )
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
        configuration: RequestConfiguration,
        polish: @escaping @Sendable (URL, String, String, Preset, String?, String) async throws -> String,
        polishViaSubscription: @escaping @Sendable (String, Preset, String?, ChatGPTSession.Credential) async throws -> String
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

        // Provider gate: nothing runs when no provider is selected.
        guard settings.provider != .none else {
            lastOutcome = .failure(PolishService.configurationMessage(for: settings))
            isRunning = false
            return
        }

        // Endpoint credentials only gate the endpoint provider; the
        // subscription provider carries its own credential.
        var key: String?
        if settings.provider == .openAICompatibleEndpoint {
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
        } else {
            key = nil
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
        let requestProvider = settings.provider
        Task { @MainActor in
            do {
                let result: String
                switch requestProvider {
                case .openAISubscription:
                    guard let credential = configuration.subscriptionCredential else {
                        throw SubscriptionError.session(
                            PolishService.configurationMessage(for: self.settings)
                        )
                    }
                    result = try await polishViaSubscription(
                        selectedText,
                        configuration.preset,
                        custom,
                        credential
                    )
                case .openAICompatibleEndpoint:
                    guard let url = configuration.baseURL,
                          let apiKey else {
                        throw EndpointError.invalidBaseURL
                    }
                    result = try await polish(
                        url,
                        configuration.model,
                        selectedText,
                        configuration.preset,
                        custom,
                        apiKey
                    )
                case .none:
                    throw EndpointError.invalidBaseURL
                }
                lastPolishProvider = requestProvider
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
