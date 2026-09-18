import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Reads a selection from apps that render text without exposing an AX text
/// element. The probe first proves that the focused application subtree has no
/// text-capable role, so native AX-backed apps never reach synthesis.
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
        let changeCount: Int
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
        applicationLacksTextSurfaces: @escaping @Sendable (pid_t) -> Bool = {
            SelectionReader.applicationLacksTextSurfaces(for: $0)
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

        let lacksTextSurfaces = await Task.detached(priority: .userInitiated) {
            applicationLacksTextSurfaces(context.processIdentifier)
        }.value
        guard lacksTextSurfaces else {
            return restore(
                snapshot,
                to: pasteboard,
                ifUnchangedSince: ownership.changeCount,
                then: .unreadable
            )
        }
        guard pasteboard.changeCount == ownership.changeCount,
              owns(pasteboard, token: ownership.token) else {
            return .clipboardFailure(.clipboardChanged)
        }
        guard capturedFocusRemainsCurrent(
            context,
            accessibilityEnabled: accessibilityEnabled,
            frontmostApplicationPID: frontmostApplicationPID,
            focusedElementResolver: focusedElementResolver
        ) else {
            return restore(
                snapshot,
                to: pasteboard,
                ifUnchangedSince: ownership.changeCount,
                then: .unreadable
            )
        }
        guard synthesizeCopy() else {
            return restore(
                snapshot,
                to: pasteboard,
                ifUnchangedSince: ownership.changeCount,
                then: .unreadable
            )
        }

        var outcome: SelectionReader.Outcome = .noSelection
        var attributedText: String?
        var expectedRestoreChangeCount = ownership.changeCount

        if pasteboard.changeCount != ownership.changeCount {
            guard let observation = stableObservation(
                of: pasteboard,
                excluding: ownership.token
            ) else {
                return .clipboardFailure(.clipboardChanged)
            }
            attributedText = observation.text
            expectedRestoreChangeCount = observation.changeCount
            outcome = .unreadable
        } else {
            for _ in 0..<pollAttempts {
                await wait(pollIntervalNanoseconds)
                guard capturedFocusRemainsCurrent(
                    context,
                    accessibilityEnabled: accessibilityEnabled,
                    frontmostApplicationPID: frontmostApplicationPID,
                    focusedElementResolver: focusedElementResolver
                ) else {
                    guard pasteboard.changeCount == ownership.changeCount else {
                        return .clipboardFailure(.clipboardChanged)
                    }
                    outcome = .unreadable
                    break
                }
                guard pasteboard.changeCount != ownership.changeCount else {
                    continue
                }
                guard let observation = stableObservation(
                    of: pasteboard,
                    excluding: ownership.token
                ) else {
                    return .clipboardFailure(.clipboardChanged)
                }
                attributedText = observation.text
                expectedRestoreChangeCount = observation.changeCount
                guard let text = observation.text, !snapshot.containsString(text) else {
                    outcome = .unreadable
                    break
                }
                outcome = text.isEmpty ? .noSelection : .selected(text)
                break
            }
        }

        let restoredChangeCount: Int
        switch restoreSnapshot(
            snapshot,
            to: pasteboard,
            ifUnchangedSince: expectedRestoreChangeCount
        ) {
        case .success(let changeCount):
            restoredChangeCount = changeCount
        case .failure(let error):
            return .clipboardFailure(error)
        }

        return await monitorLateEvents(
            after: restoredChangeCount,
            context: context,
            pasteboard: pasteboard,
            snapshot: snapshot,
            ownershipToken: ownership.token,
            initialOutcome: outcome,
            attributedText: attributedText,
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
        attributedText: String?,
        accessibilityEnabled: () -> Bool,
        frontmostApplicationPID: () -> pid_t?,
        focusedElementResolver: (pid_t) -> SelectionReader.ElementResolution,
        wait: @escaping (UInt64) async -> Void
    ) async -> SelectionReader.Outcome {
        var monitoredChangeCount = restoredChangeCount

        for _ in 0..<lateEventAttempts {
            await wait(lateEventIntervalNanoseconds)
            guard pasteboard.changeCount != monitoredChangeCount else {
                continue
            }
            guard let attributedText else {
                return initialOutcome
            }
            guard capturedFocusRemainsCurrent(
                context,
                accessibilityEnabled: accessibilityEnabled,
                frontmostApplicationPID: frontmostApplicationPID,
                focusedElementResolver: focusedElementResolver
            ), let observation = stableObservation(
                of: pasteboard,
                excluding: ownershipToken
            ), observation.text == attributedText else {
                return .clipboardFailure(.clipboardChanged)
            }

            switch restoreSnapshot(
                snapshot,
                to: pasteboard,
                ifUnchangedSince: observation.changeCount
            ) {
            case .success(let changeCount):
                monitoredChangeCount = changeCount
            case .failure(let error):
                return .clipboardFailure(error)
            }
        }

        // After this bounded window, a very late Command-C cannot be distinguished from a user copy.
        return initialOutcome
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
        guard pasteboard.writeObjects([marker]) else {
            let failedWriteChangeCount = pasteboard.changeCount
            switch restoreSnapshot(
                snapshot,
                to: pasteboard,
                ifUnchangedSince: failedWriteChangeCount
            ) {
            case .success:
                return .failure(.probeFailed)
            case .failure(let error):
                return .failure(error)
            }
        }

        let changeCount = pasteboard.changeCount
        guard owns(pasteboard, token: token),
              pasteboard.changeCount == changeCount else {
            switch restoreSnapshot(
                snapshot,
                to: pasteboard,
                ifUnchangedSince: changeCount
            ) {
            case .success:
                return .failure(.probeFailed)
            case .failure(let error):
                return .failure(error)
            }
        }
        return .success(Ownership(token: token, changeCount: changeCount))
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
        return Observation(text: text, changeCount: observedChangeCount)
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

    private static func restoreSnapshot(
        _ snapshot: ClipboardStore.Snapshot,
        to pasteboard: any PasteboardAccess,
        ifUnchangedSince expectedChangeCount: Int
    ) -> Result<Int, ClipboardError> {
        guard pasteboard.changeCount == expectedChangeCount else {
            return .failure(.clipboardChanged)
        }
        // NSPasteboard has no atomic compare-and-restore, so a write can still land after this check.
        switch ClipboardStore.restore(snapshot, to: pasteboard) {
        case .success:
            return .success(pasteboard.changeCount)
        case .failure(let error):
            return .failure(error)
        }
    }

    @MainActor
    private static func restore(
        _ snapshot: ClipboardStore.Snapshot,
        to pasteboard: any PasteboardAccess,
        ifUnchangedSince expectedChangeCount: Int,
        then outcome: SelectionReader.Outcome
    ) -> SelectionReader.Outcome {
        switch restoreSnapshot(
            snapshot,
            to: pasteboard,
            ifUnchangedSince: expectedChangeCount
        ) {
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
