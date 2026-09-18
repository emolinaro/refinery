import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Reads a selection from apps that render text without exposing an AX text
/// element. The caller must first prove that the focused application subtree
/// has no text-capable role; native AX-backed apps never enter this path.
enum ClipboardSelectionProbe {
    private static let pollAttempts = 10
    private static let pollIntervalNanoseconds: UInt64 = 30_000_000
    private static let lateEventAttempts = 30
    private static let lateEventIntervalNanoseconds: UInt64 = 100_000_000
    private static let ownershipType = NSPasteboard.PasteboardType(
        "com.refinery.selection-probe-owner"
    )

    private struct Ownership {
        let token: Data
        let changeCount: Int
    }

    private struct Observation {
        let text: String?
    }

    @MainActor
    static func read(
        for context: SelectionReader.ClipboardContext,
        pasteboard: any PasteboardAccess = NSPasteboard.general,
        accessibilityEnabled: () -> Bool = SelectionReader.isAccessibilityEnabled,
        frontmostApplicationPID: () -> pid_t? = SelectionReader.frontmostApplicationPID,
        focusedElementResolver: (pid_t) -> SelectionReader.ElementResolution = {
            SelectionReader.resolveFocusedElement(for: $0)
        },
        synthesizeCopy: () -> Bool = synthesizeCopyEvent,
        wait: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) async -> SelectionReader.Outcome {
        guard accessibilityEnabled(),
              frontmostApplicationPID() == context.processIdentifier else {
            return .unreadable
        }

        let preSnapshotChangeCount = pasteboard.changeCount
        let snapshot: ClipboardStore.Snapshot
        switch ClipboardStore.snapshot(of: pasteboard) {
        case .success(let value):
            snapshot = value
        case .failure(let error):
            return .clipboardFailure(error)
        }
        guard pasteboard.changeCount == preSnapshotChangeCount else {
            return .unreadable
        }

        let ownership: Ownership
        switch markOwnership(of: pasteboard, preserving: snapshot) {
        case .success(let value):
            ownership = value
        case .failure(let error):
            return .clipboardFailure(error)
        }

        guard capturedFocusRemainsCurrent(
            context,
            accessibilityEnabled: accessibilityEnabled,
            frontmostApplicationPID: frontmostApplicationPID,
            focusedElementResolver: focusedElementResolver
        ) else {
            return restore(snapshot, to: pasteboard, then: .unreadable)
        }
        guard synthesizeCopy() else {
            return restore(snapshot, to: pasteboard, then: .unreadable)
        }

        var outcome: SelectionReader.Outcome = .noSelection
        var attributedText: String?
        var mayAcceptLateCopy = false

        if pasteboard.changeCount != ownership.changeCount {
            attributedText = stableObservation(
                of: pasteboard,
                excluding: ownership.token
            )?.text
            outcome = .unreadable
        } else {
            var observedChange = false
            var rejected = false

            for _ in 0..<pollAttempts {
                await wait(pollIntervalNanoseconds)
                guard capturedFocusRemainsCurrent(
                    context,
                    accessibilityEnabled: accessibilityEnabled,
                    frontmostApplicationPID: frontmostApplicationPID,
                    focusedElementResolver: focusedElementResolver
                ) else {
                    outcome = .unreadable
                    rejected = true
                    break
                }
                guard pasteboard.changeCount != ownership.changeCount else {
                    continue
                }
                observedChange = true
                let observation = stableObservation(
                    of: pasteboard,
                    excluding: ownership.token
                )
                guard let observation,
                      let text = observation.text,
                      !snapshot.containsString(text) else {
                    attributedText = observation?.text
                    outcome = .unreadable
                    rejected = true
                    break
                }
                attributedText = text
                outcome = text.isEmpty ? .noSelection : .selected(text)
                break
            }

            mayAcceptLateCopy = !observedChange && !rejected
        }

        switch ClipboardStore.restore(snapshot, to: pasteboard) {
        case .failure(let error):
            return .clipboardFailure(error)
        case .success:
            break
        }

        return await monitorLateEvents(
            after: pasteboard.changeCount,
            context: context,
            pasteboard: pasteboard,
            snapshot: snapshot,
            ownershipToken: ownership.token,
            initialOutcome: outcome,
            attributedText: attributedText,
            mayAcceptFirstChange: mayAcceptLateCopy,
            accessibilityEnabled: accessibilityEnabled,
            frontmostApplicationPID: frontmostApplicationPID,
            focusedElementResolver: focusedElementResolver,
            wait: wait
        )
    }

    @MainActor
    private static func monitorLateEvents(
        after restoredChangeCount: Int,
        context: SelectionReader.ClipboardContext,
        pasteboard: any PasteboardAccess,
        snapshot: ClipboardStore.Snapshot,
        ownershipToken: Data,
        initialOutcome: SelectionReader.Outcome,
        attributedText initialAttributedText: String?,
        mayAcceptFirstChange initialMayAcceptFirstChange: Bool,
        accessibilityEnabled: () -> Bool,
        frontmostApplicationPID: () -> pid_t?,
        focusedElementResolver: (pid_t) -> SelectionReader.ElementResolution,
        wait: @escaping (UInt64) async -> Void
    ) async -> SelectionReader.Outcome {
        var monitoredChangeCount = restoredChangeCount
        var outcome = initialOutcome
        var attributedText = initialAttributedText
        var mayAcceptFirstChange = initialMayAcceptFirstChange

        for _ in 0..<lateEventAttempts {
            await wait(lateEventIntervalNanoseconds)
            guard pasteboard.changeCount != monitoredChangeCount else {
                continue
            }
            guard capturedFocusRemainsCurrent(
                context,
                accessibilityEnabled: accessibilityEnabled,
                frontmostApplicationPID: frontmostApplicationPID,
                focusedElementResolver: focusedElementResolver
            ), let observation = stableObservation(
                of: pasteboard,
                excluding: ownershipToken
            ) else {
                return outcome
            }

            if let attributedText {
                guard observation.text == attributedText else {
                    return outcome
                }
            } else {
                guard mayAcceptFirstChange else {
                    return outcome
                }
                mayAcceptFirstChange = false
                attributedText = observation.text
                guard let text = observation.text, !snapshot.containsString(text) else {
                    outcome = .unreadable
                    switch ClipboardStore.restore(snapshot, to: pasteboard) {
                    case .success:
                        monitoredChangeCount = pasteboard.changeCount
                        continue
                    case .failure(let error):
                        return .clipboardFailure(error)
                    }
                }
                outcome = text.isEmpty ? .noSelection : .selected(text)
            }

            switch ClipboardStore.restore(snapshot, to: pasteboard) {
            case .success:
                monitoredChangeCount = pasteboard.changeCount
            case .failure(let error):
                return .clipboardFailure(error)
            }
        }

        // A Command-C result after this bounded window cannot be distinguished from a later user copy.
        return outcome
    }

    private static func markOwnership(
        of pasteboard: any PasteboardAccess,
        preserving snapshot: ClipboardStore.Snapshot
    ) -> Result<Ownership, ClipboardError> {
        let token = Data(UUID().uuidString.utf8)
        let marker = NSPasteboardItem()
        guard marker.setData(token, forType: ownershipType) else {
            return .failure(.probeFailed)
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects([marker]),
              owns(pasteboard, token: token) else {
            switch ClipboardStore.restore(snapshot, to: pasteboard) {
            case .success:
                return .failure(.probeFailed)
            case .failure:
                return .failure(.restorationFailed)
            }
        }
        return .success(Ownership(token: token, changeCount: pasteboard.changeCount))
    }

    private static func stableObservation(
        of pasteboard: any PasteboardAccess,
        excluding ownershipToken: Data
    ) -> Observation? {
        let observedChangeCount = pasteboard.changeCount
        guard !owns(pasteboard, token: ownershipToken) else { return nil }
        let text = pasteboard.string(forType: .string)
        guard case .success = ClipboardStore.snapshot(of: pasteboard) else {
            return nil
        }
        guard pasteboard.changeCount == observedChangeCount,
              pasteboard.string(forType: .string) == text,
              pasteboard.changeCount == observedChangeCount,
              !owns(pasteboard, token: ownershipToken) else {
            return nil
        }
        return Observation(text: text)
    }

    private static func owns(_ pasteboard: any PasteboardAccess, token: Data) -> Bool {
        pasteboard.pasteboardItems?.contains {
            $0.data(forType: ownershipType) == token
        } == true
    }

    private static func capturedFocusRemainsCurrent(
        _ context: SelectionReader.ClipboardContext,
        accessibilityEnabled: () -> Bool,
        frontmostApplicationPID: () -> pid_t?,
        focusedElementResolver: (pid_t) -> SelectionReader.ElementResolution
    ) -> Bool {
        guard accessibilityEnabled(),
              frontmostApplicationPID() == context.processIdentifier,
              case .resolved(let focusedElement) = focusedElementResolver(
                  context.processIdentifier
              ) else {
            return false
        }
        return CFEqual(focusedElement, context.element)
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
