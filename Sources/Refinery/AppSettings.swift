import Foundation

/// User preferences persisted via `UserDefaults`.
///
/// Deliberately excludes the API key, which lives only in the Keychain.
struct AppSettings: Codable, Equatable {
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

    static func load() -> AppSettings {
        let fallback = AppSettings(
            baseURL: "https://api.ucloud-ai.com/v1",
            model: "ucloud-ai"
        )
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else {
            return fallback
        }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            return fallback
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
