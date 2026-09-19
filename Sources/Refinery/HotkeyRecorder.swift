import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Captures a global hotkey from the next key press with modifiers.
///
/// Recording runs from the settings popover. An active CGEventTap on the main
/// run loop captures the next global key combination during the session.
@MainActor
enum HotkeyRecorder {
    static var currentSession: RecordingSession?

    /// Runs a recording session on the main thread.
    /// - Parameter requestAccess: checked before the event tap is created;
    ///   callers own the prompting policy, so the app routes this through
    ///   AppModel's shared once-per-launch gate instead of firing the
    ///   system prompt here.
    /// - Parameter completion: called with (keyCode, modifiers, displayString)
    ///   on success, or (nil, nil, reason) on failure or cancellation.
    static func start(
        requestAccess: @escaping () -> Bool,
        tapFactory: @escaping RecordingSession.TapFactory,
        completion: @escaping (UInt32?, UInt32?, String) -> Void
    ) {
        currentSession?.invalidate()
        let session = RecordingSession(
            completion: completion,
            requestAccess: requestAccess,
            tapFactory: tapFactory
        )
        currentSession = session
        session.start()
    }

    /// The default access check for recording: verifies the grant without
    /// prompting. The system prompt belongs to AppModel's shared
    /// once-per-launch gate; the caller decides how a miss is surfaced.
    static func start(completion: @escaping (UInt32?, UInt32?, String) -> Void) {
        start(
            requestAccess: { SelectionReader.isAccessibilityEnabled() },
            tapFactory: RecordingSession.makeTap,
            completion: completion
        )
    }

    static func cancel() {
        currentSession?.cancel()
    }

    /// True for combinations that would intercept universal shortcuts like
    /// copy, paste, cut, undo, select-all, space or tab.
    nonisolated static func isReservedCombo(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard modifiers & UInt32(cmdKey) != 0 else { return false }
        let reserved: Set<UInt32> = [
            UInt32(kVK_ANSI_C), UInt32(kVK_ANSI_V), UInt32(kVK_ANSI_X),
            UInt32(kVK_ANSI_Z), UInt32(kVK_ANSI_A), UInt32(kVK_Space),
            UInt32(kVK_Tab),
        ]
        return reserved.contains(keyCode)
    }

    nonisolated static func isValidCombo(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let allowedModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let requiredModifiers = UInt32(cmdKey | optionKey | controlKey)
        return keyCode <= 127
            && !isModifierKeyCode(keyCode)
            && modifiers & ~allowedModifiers == 0
            && modifiers & requiredModifiers != 0
            && !isReservedCombo(keyCode: keyCode, modifiers: modifiers)
    }

    nonisolated fileprivate static func isModifierKeyCode(_ keyCode: UInt32) -> Bool {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift, kVK_Command, kVK_RightCommand,
             kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl,
             kVK_CapsLock, kVK_Function:
            return true
        default:
            return false
        }
    }

    /// Converts CoreGraphics event flags to a Carbon modifier mask.
    static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.maskCommand) { result |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { result |= UInt32(optionKey) }
        if flags.contains(.maskControl) { result |= UInt32(controlKey) }
        if flags.contains(.maskShift) { result |= UInt32(shiftKey) }
        return result
    }

    /// Human-readable description of a Carbon keycode + modifier mask.
    static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyLabel(keyCode))
        return parts.joined()
    }

    /// Maps a Carbon virtual keycode to its display character (letters, digits, punctuation).
    static func keyLabel(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Grave: return "`"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        default: return "Key \(keyCode)"
        }
    }
}

/// A single recording session: owns an active event tap and ends itself
/// when a combination is captured, on Escape, app deactivation, or explicit
/// cancellation.
@MainActor
final class RecordingSession {
    typealias TapFactory = (
        CGEventTapLocation,
        CGEventTapPlacement,
        CGEventTapOptions,
        CGEventMask,
        CGEventTapCallBack,
        UnsafeMutableRawPointer
    ) -> CFMachPort?
    typealias TapEnabler = (CFMachPort) -> Void

    private let completion: (UInt32?, UInt32?, String) -> Void
    private let requestAccess: () -> Bool
    private let tapFactory: TapFactory
    private let tapEnabler: TapEnabler
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []
    private var finished = false
    private var pendingResult: (keyCode: UInt32?, modifiers: UInt32?, reason: String)?
    private var pendingKeyCode: UInt32?

    init(
        completion: @escaping (UInt32?, UInt32?, String) -> Void,
        requestAccess: @escaping () -> Bool,
        tapFactory: @escaping TapFactory,
        tapEnabler: @escaping TapEnabler = { tap in
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    ) {
        self.completion = completion
        self.requestAccess = requestAccess
        self.tapFactory = tapFactory
        self.tapEnabler = tapEnabler
        installEndObservers()
    }

    func start() {
        guard requestAccess() else {
            finish(
                keyCode: nil,
                modifiers: nil,
                reason: "Accessibility permission is required to record a hotkey."
            )
            return
        }
        guard !finished else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let session = Unmanaged<RecordingSession>.fromOpaque(userInfo).takeUnretainedValue()
            MainActor.assumeIsolated {
                session.handleTapEvent(type, event: event)
            }
            return nil
        }
        guard let tap = tapFactory(
            .cgSessionEventTap,
            .headInsertEventTap,
            .defaultTap,
            mask,
            callback,
            Unmanaged.passUnretained(self).toOpaque()
        ) else {
            finish(
                keyCode: nil,
                modifiers: nil,
                reason: "Could not capture keyboard events; check Accessibility permission."
            )
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            self.tap = tap
            finish(
                keyCode: nil,
                modifiers: nil,
                reason: "Could not listen for keyboard events."
            )
            return
        }
        self.tap = tap
        self.runLoopSource = source
        CFRunLoopAddSource(RunLoop.main.getCFRunLoop(), source, .commonModes)
        tapEnabler(tap)
    }

    /// Observes menu tracking and app deactivation events that end the session
    /// early. The app delegate cancels separately when the settings popover
    /// closes.
    private func installEndObservers() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finish(keyCode: nil, modifiers: nil, reason: "Cancelled.")
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finish(keyCode: nil, modifiers: nil, reason: "Cancelled.")
            }
        })
    }

    func invalidate() {
        finished = true
        teardown()
    }

    func cancel() {
        finish(keyCode: nil, modifiers: nil, reason: "Cancelled.")
    }

    private func handleTapEvent(_ type: CGEventType, event: CGEvent) {
        guard !finished else { return }
        switch type {
        case .tapDisabledByTimeout:
            if let tap {
                tapEnabler(tap)
            }
        case .tapDisabledByUserInput:
            finish(
                keyCode: nil,
                modifiers: nil,
                reason: "Keyboard capture was disabled; try recording the hotkey again."
            )
        default:
            handle(event)
        }
    }

    func handle(_ event: CGEvent) {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))

        if event.type == .keyUp {
            guard keyCode == pendingKeyCode, let pendingResult else { return }
            finish(
                keyCode: pendingResult.keyCode,
                modifiers: pendingResult.modifiers,
                reason: pendingResult.reason
            )
            return
        }

        guard event.type == .keyDown else { return }
        guard pendingResult == nil else { return }

        if Int(keyCode) == kVK_Escape {
            pendingKeyCode = keyCode
            pendingResult = (nil, nil, "Cancelled.")
            return
        }

        if HotkeyRecorder.isModifierKeyCode(keyCode) { return }

        let required: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        if event.flags.intersection(required).isEmpty { return }

        let modifiers = HotkeyRecorder.carbonModifiers(from: event.flags)
        if HotkeyRecorder.isReservedCombo(keyCode: keyCode, modifiers: modifiers) {
            pendingKeyCode = keyCode
            pendingResult = (nil, nil, "That combination conflicts with a common system shortcut.")
            return
        }

        let display = HotkeyRecorder.displayString(keyCode: keyCode, modifiers: modifiers)
        pendingKeyCode = keyCode
        pendingResult = (keyCode, modifiers, display)
    }

    private func finish(keyCode: UInt32?, modifiers: UInt32?, reason: String) {
        guard !finished else { return }
        finished = true
        teardown()
        completion(keyCode, modifiers, reason)
    }

    private func teardown() {
        if let runLoopSource {
            CFRunLoopRemoveSource(RunLoop.main.getCFRunLoop(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        if let tap {
            CFMachPortInvalidate(tap)
        }
        tap = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        if HotkeyRecorder.currentSession === self {
            HotkeyRecorder.currentSession = nil
        }
    }

    static func makeTap(
        location: CGEventTapLocation,
        placement: CGEventTapPlacement,
        options: CGEventTapOptions,
        mask: CGEventMask,
        callback: @escaping CGEventTapCallBack,
        userInfo: UnsafeMutableRawPointer
    ) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: location,
            place: placement,
            options: options,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        )
    }
}
