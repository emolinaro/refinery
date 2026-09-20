import AppKit
import Carbon.HIToolbox
import CoreGraphics

@MainActor
protocol FocusContinuityMonitoring: AnyObject {
    var remainedFocused: Bool { get }
    func stop()
}

/// The sticky focus-continuity state plus the handler for the target app's
/// focused-element announcements. An announcement breaks continuity only when
/// focus no longer resolves to the captured element: AX-hostile editors
/// (Sublime Text) re-announce their unchanged focused element while handling
/// the probe's own synthesized Command-C, and that re-announcement is not a
/// focus break.
final class FocusContinuitySignal: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    private let revalidate: @Sendable () -> Bool

    init(revalidate: @escaping @Sendable () -> Bool) {
        self.revalidate = revalidate
        value = revalidate()
    }

    var remainedFocused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func invalidate() {
        lock.lock()
        value = false
        lock.unlock()
    }

    /// Runs when the target app announces a focused-element change (on the
    /// main thread, from the AX observer's run loop source). The announcement
    /// is only a focus break when the revalidation - accessibility permission,
    /// frontmost application, and resolved focused-element identity - no
    /// longer holds; a re-announcement that still resolves to the captured
    /// element leaves continuity intact.
    func focusedElementChanged() {
        if !revalidate() {
            invalidate()
        }
    }
}

private func focusContinuityDidChange(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<FocusContinuitySignal>
        .fromOpaque(refcon)
        .takeUnretainedValue()
        .focusedElementChanged()
}

@MainActor
private final class ApplicationFocusContinuityMonitor: FocusContinuityMonitoring {
    private let currentFocus: @MainActor @Sendable () -> Bool
    private let signal: FocusContinuitySignal
    private var workspaceObserver: NSObjectProtocol?
    private var accessibilityObserver: AXObserver?
    private var observedApplication: AXUIElement?

    /// `currentFocus` fully revalidates the captured focus - accessibility
    /// permission, frontmost application, and the resolved focused element's
    /// identity - and runs on the main thread. The AX notification and
    /// workspace observers below deliver on the main thread, so the
    /// nonisolated signal hops there before revalidating.
    init(
        context: SelectionReader.ClipboardContext,
        currentFocus: @escaping @MainActor @Sendable () -> Bool
    ) {
        let targetProcessIdentifier = context.processIdentifier
        self.currentFocus = currentFocus
        let signal = FocusContinuitySignal(revalidate: { @Sendable [currentFocus] in
            MainActor.assumeIsolated { currentFocus() }
        })
        self.signal = signal

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [signal, targetProcessIdentifier] notification in
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication,
            application.processIdentifier == targetProcessIdentifier else {
                signal.invalidate()
                return
            }
        }

        var observer: AXObserver?
        guard AXObserverCreate(
            targetProcessIdentifier,
            focusContinuityDidChange,
            &observer
        ) == .success,
        let observer else {
            return
        }
        let application = AXUIElementCreateApplication(targetProcessIdentifier)
        guard AXObserverAddNotification(
            observer,
            application,
            kAXFocusedUIElementChangedNotification as CFString,
            Unmanaged.passUnretained(signal).toOpaque()
        ) == .success else {
            return
        }
        accessibilityObserver = observer
        observedApplication = application
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }

    var remainedFocused: Bool {
        if !currentFocus() {
            signal.invalidate()
        }
        return signal.remainedFocused
    }

    func stop() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        if let accessibilityObserver, let observedApplication {
            AXObserverRemoveNotification(
                accessibilityObserver,
                observedApplication,
                kAXFocusedUIElementChangedNotification as CFString
            )
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(accessibilityObserver),
                .commonModes
            )
            self.accessibilityObserver = nil
            self.observedApplication = nil
        }
    }
}

/// Reads a selection from apps that render text without exposing an AX text
/// element. For element-anchored contexts the probe first proves that the
/// focused application subtree has no text-capable role, so native AX-backed
/// apps never reach synthesis. Elementless contexts - no focused element ever
/// resolved - skip that proof because the AX path is impossible there and the
/// guarded probe is the only possible read.
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

    enum OwnershipEvent: Equatable, Sendable {
        case began
        case endedSafely
        case restorationFailed
    }

    typealias OwnershipHandler = @MainActor @Sendable (OwnershipEvent) -> Void
    /// The second argument fully revalidates the captured focus (accessibility
    /// permission, frontmost application, resolved focused-element identity)
    /// and runs on the main thread.
    typealias FocusContinuityFactory = @MainActor (
        SelectionReader.ClipboardContext,
        @escaping @MainActor @Sendable () -> Bool
    ) -> any FocusContinuityMonitoring

    @MainActor
    static func read(
        for context: SelectionReader.ClipboardContext,
        pasteboard: any PasteboardAccess = NSPasteboard.general,
        accessibilityEnabled: @escaping () -> Bool = SelectionReader.isAccessibilityEnabled,
        frontmostApplicationPID: @escaping () -> pid_t? = SelectionReader.frontmostApplicationPID,
        focusedElementResolver: @escaping (pid_t) -> SelectionReader.ElementResolution = {
            SelectionReader.resolveFocusedElement(for: $0)
        },
        applicationLacksTextSurfaces: @escaping @Sendable (pid_t) -> Bool = {
            SelectionReader.applicationLacksTextSurfaces(for: $0)
        },
        focusContinuityMonitor: FocusContinuityFactory = { context, currentFocus in
            ApplicationFocusContinuityMonitor(
                context: context,
                currentFocus: currentFocus
            )
        },
        ownershipChanged: OwnershipHandler = { _ in },
        synthesizeCopy: () -> Bool = synthesizeCopyEvent,
        wait: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) async -> SelectionReader.Outcome {
        guard accessibilityEnabled(),
              frontmostApplicationPID() == context.processIdentifier else {
            return .unreadable
        }

        // The text-surface proof keeps the probe away from apps whose AX tree
        // can expose the selection directly, where the primary AX path is
        // strictly better. It is vacuous for elementless contexts - the
        // Electron shape, where no focused element ever resolved - so those
        // skip it and every remaining guard applies unchanged.
        if context.element != nil {
            let preflightChangeCount = pasteboard.changeCount
            let preflightLacksTextSurfaces = await readApplicationLacksTextSurfaces(
                for: context.processIdentifier,
                reader: applicationLacksTextSurfaces
            )
            guard pasteboard.changeCount == preflightChangeCount else {
                return .clipboardFailure(.clipboardChanged)
            }
            guard preflightLacksTextSurfaces else {
                return .unreadable
            }
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

        if context.element != nil {
            guard await readApplicationLacksTextSurfaces(
                for: context.processIdentifier,
                reader: applicationLacksTextSurfaces
            ) else {
                return .unreadable
            }
        }
        guard capturedFocusRemainsCurrent(
            context,
            accessibilityEnabled: accessibilityEnabled,
            frontmostApplicationPID: frontmostApplicationPID,
            focusedElementResolver: focusedElementResolver
        ) else {
            return .unreadable
        }

        let focusContinuity = focusContinuityMonitor(context) {
            capturedFocusRemainsCurrent(
                context,
                accessibilityEnabled: accessibilityEnabled,
                frontmostApplicationPID: frontmostApplicationPID,
                focusedElementResolver: focusedElementResolver
            )
        }
        defer { focusContinuity.stop() }
        guard focusContinuity.remainedFocused else {
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

        ownershipChanged(.began)
        var ownershipFinished = false
        func finishOwnership(_ event: OwnershipEvent) {
            guard !ownershipFinished else { return }
            ownershipFinished = true
            ownershipChanged(event)
        }
        func finishOwnership(after error: ClipboardError) {
            finishOwnership(
                error == .restorationFailed ? .restorationFailed : .endedSafely
            )
        }
        func finishOwnership(after outcome: SelectionReader.Outcome) {
            if case .clipboardFailure(let error) = outcome {
                finishOwnership(after: error)
            } else {
                finishOwnership(.endedSafely)
            }
        }
        func restoreAndFinish(
            ifUnchangedSince expectedChangeCount: Int,
            then outcome: SelectionReader.Outcome
        ) -> SelectionReader.Outcome {
            switch restoreSnapshot(
                snapshot,
                to: pasteboard,
                ifUnchangedSince: expectedChangeCount
            ) {
            case .success:
                finishOwnership(.endedSafely)
                return outcome
            case .failure(let error):
                finishOwnership(after: error)
                return .clipboardFailure(error)
            }
        }
        defer {
            if !ownershipFinished {
                ownershipChanged(.restorationFailed)
            }
        }

        guard pasteboard.changeCount == ownership.changeCount,
              owns(pasteboard, token: ownership.token) else {
            finishOwnership(.endedSafely)
            return .clipboardFailure(.clipboardChanged)
        }
        guard focusContinuity.remainedFocused else {
            return restoreAndFinish(
                ifUnchangedSince: ownership.changeCount,
                then: .unreadable
            )
        }
        guard synthesizeCopy() else {
            return restoreAndFinish(
                ifUnchangedSince: ownership.changeCount,
                then: .unreadable
            )
        }
        guard pasteboard.changeCount == ownership.changeCount,
              owns(pasteboard, token: ownership.token) else {
            finishOwnership(.endedSafely)
            return .clipboardFailure(.clipboardChanged)
        }

        var outcome: SelectionReader.Outcome = .noSelection
        var expectedRestoreChangeCount = ownership.changeCount
        var focusRemainedContinuous = focusContinuity.remainedFocused
        var initialPollExpired = true

        for _ in 0..<pollAttempts {
            await wait(pollIntervalNanoseconds)
            if !focusContinuity.remainedFocused {
                focusRemainedContinuous = false
            }
            guard pasteboard.changeCount != ownership.changeCount else {
                continue
            }
            guard let observation = stableObservation(
                of: pasteboard,
                excluding: ownership.token
            ) else {
                finishOwnership(.endedSafely)
                return .clipboardFailure(.clipboardChanged)
            }
            initialPollExpired = false
            expectedRestoreChangeCount = observation.changeCount
            guard pasteboard.changeCount == observation.changeCount else {
                finishOwnership(.endedSafely)
                return .clipboardFailure(.clipboardChanged)
            }
            guard focusRemainedContinuous else {
                outcome = .unreadable
                break
            }
            // A copy equal to the pre-probe clipboard is a valid selection:
            // the common flow copies the text first, then hotkeys the same
            // selection. The stale-read case this used to guard against
            // cannot reach here - a pasteboard never re-written still holds
            // the ownership token and is rejected above - and the equal-text
            // rejection made that common flow read as "no selection".
            // macOS exposes no pasteboard writer identity. A same-moment background write can
            // still win while the target remains focused; the tight window and continuous focus
            // lease are the strongest corroboration available for AX-hostile applications.
            guard let text = observation.text else {
                outcome = .noSelection
                break
            }
            outcome = text.isEmpty ? .noSelection : .selected(text)
            break
        }
        if !focusRemainedContinuous, case .noSelection = outcome {
            outcome = .unreadable
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
            finishOwnership(after: error)
            return .clipboardFailure(error)
        }

        if case .selected(let text) = outcome {
            guard pasteboard.changeCount == restoredChangeCount else {
                finishOwnership(.endedSafely)
                return .clipboardFailure(.clipboardChanged)
            }
            if focusContinuity.remainedFocused {
                finishOwnership(.endedSafely)
                return .clipboardSelection(
                    text,
                    expectedChangeCount: restoredChangeCount
                )
            }
            outcome = .unreadable
        }

        let monitoredOutcome = await monitorLateEvents(
            after: restoredChangeCount,
            restoring: snapshot,
            pasteboard: pasteboard,
            initialOutcome: outcome,
            initialPollExpired: initialPollExpired,
            wait: wait
        )
        finishOwnership(after: monitoredOutcome)
        return monitoredOutcome
    }

    @MainActor
    private static func monitorLateEvents(
        after restoredChangeCount: Int,
        restoring snapshot: ClipboardStore.Snapshot,
        pasteboard: any PasteboardAccess,
        initialOutcome: SelectionReader.Outcome,
        initialPollExpired: Bool,
        wait: @escaping (UInt64) async -> Void
    ) async -> SelectionReader.Outcome {
        for _ in 0..<lateEventAttempts {
            await wait(lateEventIntervalNanoseconds)
            guard pasteboard.changeCount != restoredChangeCount else {
                continue
            }
            guard initialPollExpired else {
                return .clipboardFailure(.clipboardChanged)
            }
            let lateChangeCount = pasteboard.changeCount
            // Restoring the pre-probe snapshot takes priority in this bounded race even
            // if the write was a genuine user copy. The visible timeout keeps it non-silent.
            switch restoreSnapshot(
                snapshot,
                to: pasteboard,
                ifUnchangedSince: lateChangeCount
            ) {
            case .success:
                return .clipboardFailure(.selectionReadTimedOut)
            case .failure(let error):
                return .clipboardFailure(error)
            }
        }
        return initialOutcome
    }

    private static func readApplicationLacksTextSurfaces(
        for processIdentifier: pid_t,
        reader: @escaping @Sendable (pid_t) -> Bool
    ) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            reader(processIdentifier)
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
              frontmostApplicationPID() == context.processIdentifier else {
            return false
        }
        // With no captured element identity - the Electron shape, where the
        // focused element never resolved - the frontmost PID lease alone
        // carries focus continuity; every other guard is unchanged.
        guard let capturedElement = context.element else {
            return true
        }
        guard case .resolved(let focusedElement) = focusedElementResolver(
            context.processIdentifier
        ) else {
            return false
        }
        return CFEqual(focusedElement, capturedElement)
    }

    private static func restoreSnapshot(
        _ snapshot: ClipboardStore.Snapshot,
        to pasteboard: any PasteboardAccess,
        ifUnchangedSince expectedChangeCount: Int
    ) -> Result<Int, ClipboardError> {
        // NSPasteboard has no atomic compare-and-restore, so a write can still land after this check.
        switch ClipboardStore.restoreWithChangeCount(
            snapshot,
            to: pasteboard,
            ifUnchangedSince: expectedChangeCount
        ) {
        case .success(let changeCount):
            return .success(changeCount)
        case .failure(let error):
            return .failure(error)
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
