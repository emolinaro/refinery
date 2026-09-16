import AppKit
import Combine
import SwiftUI

/// Application state: settings, preset selection, hotkey handling and the
/// polish pipeline (selection -> endpoint -> clipboard).
@MainActor
final class AppModel: ObservableObject {
    // MARK: Published state
    @Published var settings = AppSettings.load()
    @Published var lastOutcome: Outcome?
    @Published var apiKeyPresent = KeychainStore.hasAPIKey()
    @Published var isRunning = false

    enum Outcome: Equatable {
        case polished
        case emptySelection
        case failure(String)
    }

    private let hotkeyCenter = HotkeyCenter()

    /// Exposes hotkey wiring to the app delegate.
    func setTrigger(_ handler: @escaping () -> Void) {
        hotkeyCenter.onTrigger = handler
    }

    init() {
        applyHotkey()
    }

    // MARK: Settings
    func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        settings.save()
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
            lastOutcome = .failure("Could not register hotkey; it may be in use by another app.")
        }
    }

    // MARK: The pipeline
    func handleHotkey() {
        guard !isRunning else { return }

        guard SelectionReader.isAccessibilityEnabled() else {
            lastOutcome = .failure("Accessibility permission is required to read the selected text.")
            SelectionReader.promptForAccessibility()
            return
        }

        guard let selected = SelectionReader.readSelectedText(),
              !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastOutcome = .emptySelection
            return
        }

        // Custom preset requires a typed prompt; the panel returns nil when cancelled.
        var customPrompt: String?
        if settings.preset == .customOneOff {
            guard let typed = CustomPromptPanel.prompt(), !typed.isEmpty else { return }
            customPrompt = typed
        }

        guard let url = baseURL, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            lastOutcome = .failure(EndpointError.invalidBaseURL.localizedDescription)
            return
        }

        guard let key = KeychainStore.readAPIKey() else {
            lastOutcome = .failure(EndpointError.missingAPIKey.localizedDescription)
            return
        }

        isRunning = true
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
                ClipboardStore.write(result)
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
