import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Reads a selection from apps that render text without exposing an AX text
/// element. The caller must first prove that the focused AX subtree has no
/// text-capable role; native AX-backed apps never enter this path.
enum ClipboardSelectionProbe {
    private static let pollAttempts = 10
    private static let pollIntervalNanoseconds: UInt64 = 30_000_000

    @MainActor
    static func read(
        for processIdentifier: pid_t,
        pasteboard: any PasteboardAccess = NSPasteboard.general,
        accessibilityEnabled: () -> Bool = SelectionReader.isAccessibilityEnabled,
        frontmostApplicationPID: () -> pid_t? = SelectionReader.frontmostApplicationPID,
        synthesizeCopy: () -> Bool = synthesizeCopyEvent,
        wait: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) async -> SelectionReader.Outcome {
        guard accessibilityEnabled(),
              frontmostApplicationPID() == processIdentifier else {
            return .unreadable
        }

        let snapshot: ClipboardStore.Snapshot
        switch ClipboardStore.snapshot(of: pasteboard) {
        case .success(let value):
            snapshot = value
        case .failure(let error):
            return .clipboardFailure(error)
        }

        let initialChangeCount = pasteboard.changeCount
        guard synthesizeCopy() else {
            return restore(snapshot, to: pasteboard, then: .unreadable)
        }

        var outcome: SelectionReader.Outcome = .noSelection
        for attempt in 0..<pollAttempts {
            guard frontmostApplicationPID() == processIdentifier else {
                outcome = .unreadable
                break
            }
            if pasteboard.changeCount != initialChangeCount {
                if let selected = pasteboard.string(forType: .string) {
                    outcome = selected.isEmpty ? .noSelection : .selected(selected)
                } else {
                    outcome = .unreadable
                }
                break
            }
            if attempt + 1 < pollAttempts {
                await wait(pollIntervalNanoseconds)
            }
        }

        return restore(snapshot, to: pasteboard, then: outcome)
    }

    @MainActor
    private static func restore(
        _ snapshot: ClipboardStore.Snapshot,
        to pasteboard: any PasteboardAccess,
        then outcome: SelectionReader.Outcome
    ) -> SelectionReader.Outcome {
        switch ClipboardStore.restore(snapshot, to: pasteboard) {
        case .success:
            return outcome
        case .failure(let error):
            return .clipboardFailure(error)
        }
    }

    private static func synthesizeCopyEvent() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_C),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_C),
                  keyDown: false
              ) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
