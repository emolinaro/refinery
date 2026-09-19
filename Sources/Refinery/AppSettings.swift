import Foundation
import Carbon.HIToolbox

/// User preferences persisted via `UserDefaults`.
///
/// Deliberately excludes the API key, which lives only in the Keychain.
struct AppSettings: Codable, Equatable {
    enum LoadError: Error {
        case unreadable
    }

    /// Which provider serves polish requests. Defaults to none: the
    /// v0.1.x custom endpoint stays available but nothing runs until the
    /// user picks a provider.
    var provider: ProviderSelection = .none

    enum CodingKeys: String, CodingKey {
        case provider
        case baseURL
        case model
        case preset
        case hotkeyKeyCode
        case hotkeyModifiers
    }

    init(
        provider: ProviderSelection = .none,
        baseURL: String,
        model: String,
        preset: Preset = .polish,
        hotkeyKeyCode: Int = 35,
        hotkeyModifiers: Int = 2304
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.preset = preset
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyModifiers = hotkeyModifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // v0.1.x settings carry no provider; they decode as `.none` so an
        // upgrade never strands existing installs in the unreadable state.
        provider = try container.decodeIfPresent(ProviderSelection.self, forKey: .provider) ?? .none
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        preset = try container.decodeIfPresent(Preset.self, forKey: .preset) ?? .polish
        hotkeyKeyCode = try container.decodeIfPresent(Int.self, forKey: .hotkeyKeyCode) ?? 35
        hotkeyModifiers = try container.decodeIfPresent(Int.self, forKey: .hotkeyModifiers) ?? 2304
    }
    /// OpenAI-compatible base URL. The fallback is a private deployment example.
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
            let keyCode = UInt32(exactly: settings.hotkeyKeyCode)
            let modifiers = UInt32(exactly: settings.hotkeyModifiers)
            guard let keyCode, let modifiers,
                  HotkeyRecorder.isValidCombo(keyCode: keyCode, modifiers: modifiers),
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
