import Foundation
import Carbon.HIToolbox

/// User preferences persisted via `UserDefaults`.
///
/// Deliberately excludes the API key, which lives only in the Keychain.
struct AppSettings: Codable, Equatable {
    enum LoadError: Error {
        case unreadable
    }

    /// OpenAI-compatible base URL, e.g. "https://api.ucloud-ai.com/v1".
    var baseURL: String
    /// Model name sent to chat completions.
    var model: String
    /// The currently selected preset (menu-bar choice).
    var preset: Preset = .polish
    /// Recorded global hotkey, as a Carbon virtual keycode (35 = "P").
    var hotkeyKeyCode: Int = 35
    /// Recorded modifier flags, as raw Carbon modifier mask (cmdKey | optionKey).
    var hotkeyModifiers: Int = 2304

    static let defaultsKey = "com.refinery.app.settings"

    static func load(from defaults: UserDefaults = .standard) throws -> AppSettings {
        let fallback = AppSettings(
            baseURL: "https://api.ucloud-ai.com/v1",
            model: "ucloud-ai"
        )
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            return fallback
        }
        do {
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            let allowedModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
            let requiredModifiers = UInt32(cmdKey | optionKey | controlKey)
            guard let keyCode = UInt32(exactly: settings.hotkeyKeyCode), keyCode <= 127,
                  let modifiers = UInt32(exactly: settings.hotkeyModifiers),
                  modifiers & ~allowedModifiers == 0,
                  modifiers & requiredModifiers != 0,
                  !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LoadError.unreadable
            }
            return settings
        } catch {
            throw LoadError.unreadable
        }
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
