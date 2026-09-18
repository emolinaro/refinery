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
    private let readSelection: @Sendable () -> SelectionReader.Outcome

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
        readSelection: @escaping @Sendable () -> SelectionReader.Outcome = {
            SelectionReader.readSelection()
        }
    ) {
        self.settings = settings
        self.settingsAreReadable = settingsAreReadable
        self.hotkeyCenter = hotkeyCenter
        self.persistSettings = persistSettings
        self.accessibilityEnabled = accessibilityEnabled
        self.accessibilityPrompt = accessibilityPrompt
        self.readSelection = readSelection
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

        guard settingsAreReadable else {
            lastOutcome = .failure("Settings are unreadable. Re-open Refinery settings to reconfigure the endpoint.")
            return
        }

        guard accessibilityEnabled() else {
            lastOutcome = .failure("Accessibility permission is required to read the selected text.")
            accessibilityPrompt()
            return
        }

        isRunning = true
        let readSelection = self.readSelection
        Task { [weak self] in
            let selection = await Task.detached(priority: .userInitiated) {
                readSelection()
            }.value
            self?.handle(selection: selection)
        }
    }

    private func handle(selection: SelectionReader.Outcome) {
        let selected: String
        switch selection {
        case .selected(let text):
            selected = text
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
        }

        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastOutcome = .emptySelection
            isRunning = false
            return
        }

        guard let url = baseURL, EndpointClient.isAllowedBaseURL(url) else {
            lastOutcome = .failure(EndpointError.invalidBaseURL.localizedDescription)
            isRunning = false
            return
        }

        let key: String
        do {
            guard let savedKey = try KeychainStore.readAPIKey(for: url) else {
                lastOutcome = .failure(EndpointError.missingAPIKey.localizedDescription)
                isRunning = false
                return
            }
            key = savedKey
        } catch {
            lastOutcome = .failure(error.localizedDescription)
            isRunning = false
            return
        }

        // Custom preset requires a typed prompt; the panel returns nil when cancelled.
        var customPrompt: String?
        if settings.preset == .customOneOff {
            guard let typed = CustomPromptPanel.prompt() else {
                isRunning = false
                return
            }
            customPrompt = typed
        }

        let preset = settings.preset
        let model = settings.model
        let selectedText = selected
        let custom = customPrompt
        let apiKey = key
        Task { @MainActor in
            do {
                let result = try await run(
                    baseURL: url,
                    model: model,
                    text: selectedText,
                    preset: preset,
                    custom: custom,
                    key: apiKey
                )
                switch ClipboardStore.writeResult(result, to: NSPasteboard.general) {
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

    /// Runs the polish off the main actor to satisfy strict concurrency checking.
    private nonisolated func run(
        baseURL: URL,
        model: String,
        text: String,
        preset: Preset,
        custom: String?,
        key: String
    ) async throws -> String {
        let client = EndpointClient(baseURL: baseURL, model: model)
        return try await client.polish(text, preset: preset, customPrompt: custom, apiKey: key)
    }
}
