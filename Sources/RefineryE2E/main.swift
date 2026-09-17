import AppKit
import Foundation
import Refinery

@main
struct RefineryE2E {
    @MainActor
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        let base = required("E2E_BASE_URL", in: env)
        guard let baseURL = URL(string: base),
              baseURL.scheme != nil,
              baseURL.host != nil else {
            fail("invalid base URL \(base)", code: 2)
        }

        let model = required("E2E_MODEL", in: env)
        let presetName = required("E2E_PRESET", in: env)
        guard let preset = Preset(rawValue: presetName) else {
            fail("invalid preset \(presetName)", code: 2)
        }
        let input = required("E2E_INPUT", in: env)
        let custom = env["E2E_CUSTOM_PROMPT"]
        let key = required("E2E_DUMMY_KEY", in: env)
        let timeoutValue = required("E2E_TIMEOUT", in: env)
        guard let timeout = TimeInterval(timeoutValue), timeout.isFinite, timeout > 0 else {
            fail("invalid timeout \(timeoutValue)", code: 2)
        }

        do {
            let client = EndpointClient(baseURL: baseURL, model: model, timeout: timeout)
            let result = try await client.polish(input, preset: preset, customPrompt: custom, apiKey: key)
            let pasteboard = NSPasteboard(name: .init("RefineryE2E.\(UUID().uuidString)"))
            guard ClipboardStore.write(result, to: pasteboard),
                  pasteboard.string(forType: .string) == result else {
                fail("clipboard write failed")
            }
            print("E2E: polished and copied: \(result)")
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func required(_ name: String, in environment: [String: String]) -> String {
        guard let value = environment[name],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("missing required environment variable \(name)", code: 2)
        }
        return value
    }

    private static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("E2E ERROR: \(message)\n".utf8))
        exit(code)
    }
}
