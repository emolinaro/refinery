import SwiftUI

/// Settings UI reachable from the menu-bar icon: endpoint URL, model, API key,
/// preset picker and hotkey recording.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    @State private var draftBaseURL = ""
    @State private var draftModel = ""
    @State private var draftAPIKey = ""
    @State private var recordingHotkey = false
    @State private var hotkeyFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Endpoint")
                .font(.headline)

            LabeledContent {
                TextField("https://api.ucloud-ai.com/v1", text: $draftBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            } label: {
                Text("Base URL")
            }

            LabeledContent {
                TextField("ucloud-ai", text: $draftModel)
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

            Divider()

            LabeledContent {
                HStack {
                    Text(recordedHotkeyLabel)
                    Button(recordingHotkey ? "Press keys…" : "Record") {
                        recordingHotkey = true
                        model.suspendHotkey()
                        HotkeyRecorder.start { keyCode, modifiers, display in
                            recordingHotkey = false
                            if let keyCode, let modifiers {
                                if model.adoptHotkey(keyCode: Int(keyCode), modifiers: Int(modifiers)) {
                                    hotkeyFeedback = "Hotkey set to \(display)"
                                } else {
                                    hotkeyFeedback = "Could not set \(display); the previous hotkey is kept."
                                }
                            } else {
                                model.applyHotkey()
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

            Divider()

            HStack {
                Spacer()
                Button("Apply") {
                    model.update {
                        $0.baseURL = draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        $0.model = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .disabled(
                    draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draftModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(4)
        .frame(width: 360)
        .onAppear {
            draftBaseURL = model.settings.baseURL
            draftModel = model.settings.model
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
                hotkeyFeedback = EndpointError.invalidBaseURL.localizedDescription
                return
            }
            try KeychainStore.saveAPIKey(trimmed, for: url)
            draftAPIKey = ""
        } catch {
            hotkeyFeedback = error.localizedDescription
        }
    }
}
