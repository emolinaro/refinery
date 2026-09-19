import Foundation

/// Routes a polish request to whichever provider is selected. Keeps the
/// endpoint path (v0.1.x) byte-for-byte intact; the subscription path is a
/// new sibling, not a modification.
struct PolishService: Sendable {
    var settings: AppSettings

    /// The provider that actually serves a request under the current
    /// settings. `nil` when no provider is configured (provider == .none, or
    /// the endpoint provider with an unusable endpoint).
    var activeProvider: ProviderSelection? {
        switch settings.provider {
        case .none:
            return nil
        case .openAICompatibleEndpoint:
            guard let url = baseURL, EndpointClient.isAllowedBaseURL(url) else { return nil }
            return .openAICompatibleEndpoint
        case .openAISubscription:
            return .openAISubscription
        }
    }

    var baseURL: URL? {
        let trimmed = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed)
    }

    /// The failure message for an unusable provider, matching the Settings
    /// and dropdown copy.
    static func configurationMessage(for settings: AppSettings) -> String {
        switch settings.provider {
        case .none:
            return "No provider is selected. Choose one in Refinery settings."
        case .openAICompatibleEndpoint:
            return EndpointError.invalidBaseURL.localizedDescription
        case .openAISubscription:
            return "The OpenAI subscription is selected but not signed in. Sign in from Refinery settings."
        }
    }
}
