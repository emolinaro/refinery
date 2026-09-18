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

    private struct Eligibility: Sendable {
        let applicationLacksTextSurfaces: Bool
        let selectionEvidence: SelectionReader.SelectionEvidence
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
        selectionEvidenceReader: @escaping @Sendable (
            SelectionReader.ClipboardContext
        ) -> SelectionReader.SelectionEvidence = {
            SelectionReader.selectionEvidence(for: $0)
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

        let preflightChangeCount = pasteboard.changeCount
        let eligibility = await readEligibility(
            for: context,
            applicationLacksTextSurfaces: applicationLacksTextSurfaces,
            selectionEvidenceReader: selectionEvidenceReader
        )
        guard pasteboard.changeCount == preflightChangeCount else {
            return .clipboardFailure(.clipboardChanged)
        }
        guard eligibility.applicationLacksTextSurfaces else {
            return .unreadable
        }
        guard eligibility.selectionEvidence == .present else {
            return .clipboardFailure(.selectionUnverified)
        }
        guard capturedFocusRemainsCurrent(
            context,
            accessibilityEnabled: accessibilityEnabled,
            frontmostApplicationPID: frontmostApplicationPID,
            focusedElementResolver: focusedElementResolver
        ) else {
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
            return .clipboardFailure(.clipboardChanged)
        }

        let currentEligibility = await readEligibility(
            for: context,
            applicationLacksTextSurfaces: applicationLacksTextSurfaces,
            selectionEvidenceReader: selectionEvidenceReader
        )
        guard currentEligibility.applicationLacksTextSurfaces else {
            return .unreadable
        }
        guard currentEligibility.selectionEvidence == .present else {
            return .clipboardFailure(.selectionUnverified)
        }
        guard capturedFocusRemainsCurrent(
            context,
            accessibilityEnabled: accessibilityEnabled,
            frontmostApplicationPID: frontmostApplicationPID,
            focusedElementResolver: focusedElementResolver
        ) else {
            return .unreadable
        }

        let ownership: Ownership
        switch markOwnership(
            of: pasteboard,
            preserving: snapshot,
            ifUnchangedSince: preSnapshotChangeCount
        ) {
        case .success(let value):
            ownership = value
        case .failure(let error):
            return .clipboardFailure(error)
        }

        let immediateSelectionEvidence = await selectionEvidence(
            for: context,
            reader: selectionEvidenceReader
        )
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
        guard immediateSelectionEvidence == .present else {
            return restore(
                snapshot,
                to: pasteboard,
                ifUnchangedSince: ownership.changeCount,
                then: .clipboardFailure(.selectionUnverified)
            )
        }
        guard pasteboard.changeCount == ownership.changeCount,
              owns(pasteboard, token: ownership.token) else {
            return .clipboardFailure(.clipboardChanged)
        }
        guard synthesizeCopy() else {
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

        var outcome: SelectionReader.Outcome = .noSelection
        var expectedRestoreChangeCount = ownership.changeCount

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
            expectedRestoreChangeCount = observation.changeCount
            let observedSelectionEvidence = await selectionEvidence(
                for: context,
                reader: selectionEvidenceReader
            )
            guard pasteboard.changeCount == observation.changeCount,
                  capturedFocusRemainsCurrent(
                      context,
                      accessibilityEnabled: accessibilityEnabled,
                      frontmostApplicationPID: frontmostApplicationPID,
                      focusedElementResolver: focusedElementResolver
                  ) else {
                return .clipboardFailure(.clipboardChanged)
            }
            guard observedSelectionEvidence == .present else {
                return restore(
                    snapshot,
                    to: pasteboard,
                    ifUnchangedSince: observation.changeCount,
                    then: .clipboardFailure(.selectionUnverified)
                )
            }
            guard let text = observation.text, !snapshot.containsString(text) else {
                outcome = .noSelection
                break
            }
            // macOS exposes no public pasteboard writer identity, so an in-window write remains ambiguous.
            outcome = text.isEmpty ? .noSelection : .selected(text)
            break
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
            pasteboard: pasteboard,
            initialOutcome: outcome,
            wait: wait
        )
    }

    @MainActor
    private static func monitorLateEvents(
        after restoredChangeCount: Int,
        pasteboard: any PasteboardAccess,
        initialOutcome: SelectionReader.Outcome,
        wait: @escaping (UInt64) async -> Void
    ) async -> SelectionReader.Outcome {
        for _ in 0..<lateEventAttempts {
            await wait(lateEventIntervalNanoseconds)
            guard pasteboard.changeCount != restoredChangeCount else {
                continue
            }
            guard case .selected = initialOutcome else {
                return initialOutcome
            }
            return .clipboardFailure(.clipboardChanged)
        }

        // After this bounded window, a very late Command-C cannot be distinguished from a user copy.
        if case .selected(let text) = initialOutcome {
            return .clipboardSelection(
                text,
                expectedChangeCount: restoredChangeCount
            )
        }
        return initialOutcome
    }

    private static func readEligibility(
        for context: SelectionReader.ClipboardContext,
        applicationLacksTextSurfaces: @escaping @Sendable (pid_t) -> Bool,
        selectionEvidenceReader: @escaping @Sendable (
            SelectionReader.ClipboardContext
        ) -> SelectionReader.SelectionEvidence
    ) async -> Eligibility {
        await Task.detached(priority: .userInitiated) {
            let selectionEvidence = selectionEvidenceReader(context)
            return Eligibility(
                applicationLacksTextSurfaces: applicationLacksTextSurfaces(
                    context.processIdentifier
                ),
                selectionEvidence: selectionEvidence
            )
        }.value
    }

    private static func selectionEvidence(
        for context: SelectionReader.ClipboardContext,
        reader: @escaping @Sendable (
            SelectionReader.ClipboardContext
        ) -> SelectionReader.SelectionEvidence
    ) async -> SelectionReader.SelectionEvidence {
        await Task.detached(priority: .userInitiated) {
            reader(context)
        }.value
    }

    private static func markOwnership(
        of pasteboard: any PasteboardAccess,
        preserving snapshot: ClipboardStore.Snapshot,
        ifUnchangedSince expectedChangeCount: Int
    ) -> Result<Ownership, ClipboardError> {
        let token = Data(UUID().uuidString.utf8)
        let marker = NSPasteboardItem()
        guard marker.setData(token, forType: ownershipType) else {
            return .failure(.probeFailed)
        }

        guard pasteboard.changeCount == expectedChangeCount else {
            return .failure(.clipboardChanged)
        }
        // NSPasteboard has no atomic compare-and-clear, so a write can still land after this check.
        let clearedChangeCount = pasteboard.clearContents()
        guard pasteboard.changeCount == clearedChangeCount else {
            return .failure(.clipboardChanged)
        }
        guard pasteboard.writeObjects([marker]) else {
            guard pasteboard.changeCount == clearedChangeCount else {
                return .failure(.clipboardChanged)
            }
            switch restoreSnapshot(
                snapshot,
                to: pasteboard,
                ifUnchangedSince: clearedChangeCount
            ) {
            case .success:
                return .failure(.probeFailed)
            case .failure(let error):
                return .failure(error)
            }
        }

        guard owns(pasteboard, token: token),
              pasteboard.changeCount == clearedChangeCount else {
            return .failure(.clipboardChanged)
        }
        return .success(Ownership(token: token, changeCount: clearedChangeCount))
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
        switch ClipboardStore.restoreWithChangeCount(snapshot, to: pasteboard) {
        case .success(let changeCount):
            return .success(changeCount)
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
