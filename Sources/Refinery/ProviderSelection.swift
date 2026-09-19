import Foundation

/// Which backend serves polish requests. `none` is the default: nothing runs
/// until the user picks a provider in Settings.
enum ProviderSelection: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case openAICompatibleEndpoint
    case openAISubscription

    var id: String { rawValue }

    /// Short label shown in the Settings provider picker and the menu-bar
    /// dropdown.
    var label: String {
        switch self {
        case .none: return "None"
        case .openAICompatibleEndpoint: return "Custom OpenAI-compatible endpoint"
        case .openAISubscription: return "OpenAI subscription (ChatGPT login)"
        }
    }
}
