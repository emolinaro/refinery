import AppKit
import SwiftUI

/// Hooks the e2e smoke test into the real pipeline: builds an `EndpointClient`
/// with environment overrides (base URL, model, preset, dummy key), then runs
/// the same request/parse path the menu bar uses, writing the result to the
/// clipboard. The accessibility-selection read is not exercised here (the
/// input text comes from `E2E_INPUT`).
@MainActor
enum E2E {
    static func run() -> Never {
        let env = ProcessInfo.processInfo.environment

        let settings = AppSettings(
            baseURL: env["E2E_BASE_URL"] ?? "http://127.0.0.1:18765/v1",
            model: env["E2E_MODEL"] ?? "mock-model",
            preset: Preset(rawValue: env["E2E_PRESET"] ?? "polish") ?? .polish
        )
        let input = env["E2E_INPUT"] ?? "this is a smal test of refinery"
        let customPrompt = env["E2E_CUSTOM_PROMPT"]
        let apiKey = env["E2E_DUMMY_KEY"] ?? "dummy-key-for-tests"
        let timeout = TimeInterval(env["E2E_TIMEOUT"] ?? "5") ?? 5

        let base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = URL(string: base) else {
            print("E2E ERROR: invalid base URL \(settings.baseURL)")
            exit(2)
        }

        let model = settings.model
        let preset = settings.preset
        let custom = customPrompt
        let key = apiKey
        let inputText = input
        Task { @MainActor in
            do {
                print("E2E: sending: \(inputText)")
                let result = try await Self.polish(
                    baseURL: normalized,
                    model: model,
                    text: inputText,
                    preset: preset,
                    custom: custom,
                    key: key,
                    timeout: timeout
                )
                ClipboardStore.write(result)
                print("E2E: polished: \(result)")
                print("E2E: clipboard now: \(ClipboardStore.read() ?? "<nil>")")
                exit(0)
            } catch {
                print("E2E ERROR: \(error.localizedDescription)")
                exit(1)
            }
        }
        NSApplication.shared.run()
        exit(0)
    }

    /// Runs the polish off the main actor to satisfy strict concurrency checking.
    private nonisolated static func polish(
        baseURL: URL,
        model: String,
        text: String,
        preset: Preset,
        custom: String?,
        key: String,
        timeout: TimeInterval
    ) async throws -> String {
        let client = EndpointClient(baseURL: baseURL, model: model, timeout: timeout)
        return try await client.polish(text, preset: preset, customPrompt: custom, apiKey: key)
    }
}
