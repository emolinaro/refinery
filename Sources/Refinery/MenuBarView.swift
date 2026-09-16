import SwiftUI

/// The menu-bar UI: preset picker, status, settings, quit.
struct MenuBarView: View {
    @ObservedObject var model: AppModel

    @ViewBuilder
    private var statusLine: some View {
        switch model.lastOutcome {
        case nil:
            Text("Ready")
        case .polished:
            Text("Polished - result is on the clipboard")
        case .emptySelection:
            Text("No text selected")
        case .failure(let message):
            Text(message)
        }
    }

    var body: some View {
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

            SettingsView(model: model)

            Divider()

            Button("Quit Refinery") {
                NSApplication.shared.terminate(nil)
            }
        }
        .frame(minWidth: 260)
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12))
    }
}
