import AppKit
import SwiftUI

/// A small floating panel that collects a one-off custom prompt.
///
/// Runs via `NSApp.runModal(for:)` so the hotkey handler can treat the
/// prompt as a synchronous step: the user types an instruction (or cancels
/// with Escape) before the polish request fires.
@MainActor
enum CustomPromptPanel {
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

        let host = PanelHost(panel: panel)
        panel.contentView = NSHostingView(rootView: CustomPromptView(host: host))
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        let response = NSApp.runModal(for: panel)
        panel.close()
        if response == .OK {
            let trimmed = host.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private final class PanelHost: ObservableObject {
        let panel: NSPanel
        @Published var text = ""

        init(panel: NSPanel) {
            self.panel = panel
        }

        @MainActor
        func cancel() {
            NSApp.stopModal(withCode: .cancel)
        }

        @MainActor
        func commit() {
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
                }
            }
            .padding(16)
            .frame(width: 420)
            .onAppear { focused = true }
        }
    }
}
