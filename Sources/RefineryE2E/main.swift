import AppKit
import Foundation
import Refinery

@main
struct RefineryE2E {
    @MainActor
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        let base = env["E2E_BASE_URL"] ?? "http://127.0.0.1:18765/v1"
        guard let baseURL = URL(string: base) else {
            fail("invalid base URL \(base)", code: 2)
        }

        let model = env["E2E_MODEL"] ?? "mock-model"
        let preset = Preset(rawValue: env["E2E_PRESET"] ?? "polish") ?? .polish
        let input = env["E2E_INPUT"] ?? "this is a smal test of refinery"
        let custom = env["E2E_CUSTOM_PROMPT"]
        let key = env["E2E_DUMMY_KEY"] ?? "dummy-key-for-tests"
        let timeout = TimeInterval(env["E2E_TIMEOUT"] ?? "5") ?? 5

        do {
            let client = EndpointClient(baseURL: baseURL, model: model, timeout: timeout)
            let result = try await client.polish(input, preset: preset, customPrompt: custom, apiKey: key)
            guard ClipboardStore.write(result),
                  NSPasteboard.general.string(forType: .string) == result else {
                fail("clipboard write failed")
            }
            print("E2E: polished and copied: \(result)")
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("E2E ERROR: \(message)\n".utf8))
        exit(code)
    }
}
