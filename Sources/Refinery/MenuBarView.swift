import SwiftUI

/// The menu-bar dropdown: status, preset picker, and a Settings button that
/// opens the settings surface (text entry cannot work inside menu-tracked
/// views, so settings live in a popover outside the menu).
public struct MenuBarView: View {
    @ObservedObject var model: AppModel
    var onOpenSettings: () -> Void

    @ViewBuilder
    private var statusLine: some View {
        if model.isFinishingClipboardRestore {
            Text("Finishing clipboard restoration before quitting…")
        } else {
            switch model.lastOutcome {
            case nil:
                Text("Ready")
            case .polished:
                Text("Polished - result is on the clipboard")
            case .emptySelection:
                Text("No text selected")
            case .hotkeyRegistrationFailure:
                Text("Could not register hotkey; it may be in use by another app.")
            case .failure(let message):
                Text(message)
            }
        }
    }

    public init(model: AppModel, onOpenSettings: @escaping () -> Void) {
        self.model = model
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusLine
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if model.isRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Polishing…")
                }
            }

            Divider()

            ForEach(Preset.allCases) { preset in
                Button {
                    model.update { $0.preset = preset }
                } label: {
                    if model.settings.preset == preset {
                        Label(preset.label, systemImage: "checkmark")
                    } else {
                        Text(preset.label)
                    }
                }
            }

            Divider()

            Button("Settings…") {
                onOpenSettings()
            }

            Divider()

            Button("Quit Refinery") {
                model.requestQuit()
            }
        }
        .frame(minWidth: 260)
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12))
    }
}
