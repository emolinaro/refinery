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

    /// Runs a polish request against the selected provider.
    /// - Parameters:
    ///   - text: the captured selection.
    ///   - preset: the chosen preset.
    ///   - customPrompt: the typed instruction, only for `.customOneOff`.
    ///   - endpointAPIKey: the Keychain API key (endpoint provider only).
    ///   - subscriptionCredential: the ChatGPT bearer credential
    ///     (subscription provider only).
    func polish(
        _ text: String,
        preset: Preset,
        customPrompt: String?,
        endpointAPIKey: String?,
        subscriptionCredential: ChatGPTSession.Credential?
    ) async throws -> String {
        switch settings.provider {
        case .none:
            throw EndpointError.invalidBaseURL
        case .openAICompatibleEndpoint:
            let client = EndpointClient(baseURL: baseURL!, model: settings.model)
            return try await client.polish(text, preset: preset, customPrompt: customPrompt, apiKey: endpointAPIKey ?? "")
        case .openAISubscription:
            guard let subscriptionCredential else {
                throw SubscriptionError.session("No OpenAI subscription credential is available.")
            }
            let client = SubscriptionClient()
            return try await client.polish(
                text,
                preset: preset,
                customPrompt: customPrompt,
                credential: subscriptionCredential
            )
        }
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
