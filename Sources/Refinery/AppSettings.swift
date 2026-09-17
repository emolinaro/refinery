import Foundation

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
            guard UInt32(exactly: settings.hotkeyKeyCode) != nil,
                  UInt32(exactly: settings.hotkeyModifiers) != nil else {
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
