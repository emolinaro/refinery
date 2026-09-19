import SwiftUI

/// Settings UI shown in a popover or window: provider picker, endpoint URL,
/// model, API key, OpenAI subscription account state, and hotkey recording.
/// Text entry requires a surface outside NSMenu tracking, which steals
/// keyboard focus from menu-item views.
public struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var account: SubscriptionAccountController

    @State private var draftProvider: ProviderSelection = .none
    @State private var draftBaseURL = ""
    @State private var draftModel = ""
    @State private var draftAPIKey = ""
    @State private var recordingHotkey = false
    @State private var hotkeyFeedback: String?
    @State private var endpointFeedback: String?

    public init(model: AppModel) {
        self.model = model
        self.account = model.subscriptionAccount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Provider")
                .font(.headline)

            Picker("Provider", selection: $draftProvider) {
                ForEach(ProviderSelection.allCases) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            .pickerStyle(.radioGroup)
            .frame(width: 300, alignment: .leading)
            .onChange(of: draftProvider) { provider in
                model.select(provider: provider)
                if provider == .openAISubscription {
                    account.refreshAccountState()
                }
                endpointFeedback = nil
            }

            Divider()

            switch draftProvider {
            case .none:
                Text("Choose a provider to enable polishing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .openAICompatibleEndpoint:
                Text("Endpoint")
                    .font(.headline)

                LabeledContent {
                    TextField("https://your-endpoint.example.com/v1", text: $draftBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                } label: {
                    Text("Base URL")
                }

                LabeledContent {
                    TextField("model-name", text: $draftModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                } label: {
                    Text("Model")
                }

                LabeledContent {
                    SecureField("sk-…", text: $draftAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Button("Save Key") {
                        saveKey()
                    }
                    .disabled(draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } label: {
                    Text("API Key")
                }
                Text("Stored only in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let endpointFeedback {
                    Text(endpointFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button("Apply") {
                        applyEndpoint()
                    }
                    .disabled(
                        draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || draftModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

            case .openAISubscription:
                Text("OpenAI Subscription")
                    .font(.headline)

                subscriptionSection
            }

            Divider()

            LabeledContent {
                HStack {
                    Text(recordedHotkeyLabel)
                    Button(recordingHotkey ? "Press keys…" : "Record") {
                        recordingHotkey = true
                        model.suspendHotkey()
                        HotkeyRecorder.start(
                            requestAccess: { [model] in
                                guard !model.accessibilityIsEnabled() else { return true }
                                _ = model.handleMissingAccessibilityPermission()
                                return false
                            },
                            tapFactory: RecordingSession.makeTap
                        ) { keyCode, modifiers, display in
                            defer { model.resumeHotkey() }
                            recordingHotkey = false
                            if let keyCode, let modifiers {
                                if model.adoptHotkey(keyCode: Int(keyCode), modifiers: Int(modifiers)) {
                                    hotkeyFeedback = "Hotkey set to \(display)"
                                } else {
                                    hotkeyFeedback = "Could not set \(display); the previous hotkey is kept."
                                }
                            } else {
                                hotkeyFeedback = display
                            }
                        }
                    }
                }
            } label: {
                Text("Hotkey")
            }
            if let hotkeyFeedback {
                Text(hotkeyFeedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(4)
        .frame(width: 360)
        .onAppear {
            draftProvider = model.settings.provider
            draftBaseURL = model.settings.baseURL
            draftModel = model.settings.model
            account.refreshAccountState()
        }
    }

    /// The account state surface for the OpenAI subscription provider. Shows
    /// the signed-in email and last refresh from the codex CLI's login -
    /// never token material - plus the sign-out affordance.
    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if account.isSignedIn {
                LabeledContent {
                    Text(account.account.email ?? "Signed in")
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Account")
                }
                if let plan = account.account.planType, !plan.isEmpty {
                    LabeledContent {
                        Text(Self.planLabel(plan))
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("Plan")
                    }
                }
                if let lastRefresh = account.account.lastRefresh {
                    LabeledContent {
                        Text(Self.lastRefreshFormatter.string(from: lastRefresh))
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("Last refresh")
                    }
                }
                HStack {
                    Spacer()
                    Button("Sign Out") {
                        account.signOut()
                    }
                }
            } else {
                Text(
                    account.loginExistsOnDisk
                        ? "Refinery is signed out. The codex CLI's own login is untouched."
                        : "Sign in with `codex login` in a terminal, then reopen Refinery settings."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if account.loginExistsOnDisk {
                    HStack {
                        Spacer()
                        Button("Use codex CLI Login") {
                            account.adoptExistingLogin()
                        }
                    }
                }
            }
            Text(
                "Rides the codex CLI's ChatGPT login. Tokens stay on this machine and are sent only to OpenAI."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(width: 320, alignment: .leading)
    }

    private static let lastRefreshFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static func planLabel(_ raw: String) -> String {
        switch raw {
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "free": return "Free"
        default: return raw
        }
    }

    private var recordedHotkeyLabel: String {
        HotkeyRecorder.displayString(
            keyCode: UInt32(model.settings.hotkeyKeyCode),
            modifiers: UInt32(model.settings.hotkeyModifiers)
        )
    }

    private func saveKey() {
        let trimmed = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            guard let url = URL(string: draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  EndpointClient.isAllowedBaseURL(url) else {
                endpointFeedback = EndpointError.invalidBaseURL.localizedDescription
                return
            }
            try KeychainStore.saveAPIKey(trimmed, for: url)
            draftAPIKey = ""
            endpointFeedback = "API key saved."
        } catch {
            endpointFeedback = error.localizedDescription
        }
    }

    private func applyEndpoint() {
        if model.updateEndpoint(baseURL: draftBaseURL, model: draftModel) {
            endpointFeedback = "Endpoint settings saved."
        } else if case .failure(let message) = model.lastOutcome {
            endpointFeedback = message
        }
    }
}
