import AppKit
import SwiftUI

/// A small floating panel that collects a one-off custom prompt.
///
/// Runs via `NSApp.runModal(for:)` so the hotkey handler can treat the
/// prompt as a synchronous step: the user types an instruction (or cancels
/// with Escape) before the polish request fires.
@MainActor
enum CustomPromptPanel {
    static func normalizedPrompt(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Shows the panel and returns the typed prompt, or nil when cancelled.
    static func prompt() -> String? {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Refinery - Custom Instruction"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()

        let host = PanelHost()
        panel.contentView = NSHostingView(rootView: CustomPromptView(host: host))
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        let response = NSApp.runModal(for: panel)
        panel.close()
        if response == .OK {
            return normalizedPrompt(host.text)
        }
        return nil
    }

    private final class PanelHost: ObservableObject {
        @Published var text = ""

        @MainActor
        func cancel() {
            NSApp.stopModal(withCode: .cancel)
        }

        @MainActor
        func commit() {
            guard CustomPromptPanel.normalizedPrompt(text) != nil else { return }
            NSApp.stopModal(withCode: .OK)
        }
    }

    private struct CustomPromptView: View {
        @ObservedObject var host: PanelHost
        @FocusState private var focused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("What should Refinery do with the selected text?")
                    .font(.headline)
                TextField("e.g. Make this sound more confident", text: $host.text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { host.commit() }
                HStack {
                    Spacer()
                    Button("Cancel", action: host.cancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Polish", action: host.commit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(CustomPromptPanel.normalizedPrompt(host.text) == nil)
                }
            }
            .padding(16)
            .frame(width: 420)
            .onAppear { focused = true }
        }
    }
}
