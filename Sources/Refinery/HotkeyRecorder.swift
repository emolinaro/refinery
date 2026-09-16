import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Captures a global hotkey by listening for the next key press with modifiers.
///
/// A local event monitor (not a global one) is enough because the settings
/// window is key while recording; the user is told to press the combination.
@MainActor
enum HotkeyRecorder {
    fileprivate static var currentSession: RecordingSession?

    /// Runs a recording session on the main thread.
    /// - Parameter completion: called with (keyCode, modifiers, displayString)
    ///   on success, or (nil, nil, reason) when recording was cancelled.
    static func start(completion: @escaping (UInt32?, UInt32?, String) -> Void) {
        currentSession?.invalidate()
        let session = RecordingSession(completion: completion)
        currentSession = session
        session.start()
    }

    /// True for combinations that would intercept universal shortcuts like
    /// copy, paste, cut, undo, select-all, space or tab.
    static func isReservedCombo(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard modifiers & UInt32(cmdKey) != 0 else { return false }
        let reserved: Set<UInt32> = [
            UInt32(kVK_ANSI_C), UInt32(kVK_ANSI_V), UInt32(kVK_ANSI_X),
            UInt32(kVK_ANSI_Z), UInt32(kVK_ANSI_A), UInt32(kVK_Space),
            UInt32(kVK_Tab),
        ]
        return reserved.contains(keyCode)
    }

    /// Converts AppKit modifier flags to a Carbon modifier mask.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let mask = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if mask.contains(.command) { result |= UInt32(cmdKey) }
        if mask.contains(.option) { result |= UInt32(optionKey) }
        if mask.contains(.control) { result |= UInt32(controlKey) }
        if mask.contains(.shift) { result |= UInt32(shiftKey) }
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
        default: return "Key \(keyCode)"
        }
    }
}

/// A single recording session: owns the event monitor and ends itself when a
/// combination is captured, on Escape, or when the app is deactivated.
@MainActor
private final class RecordingSession {
    private let completion: (UInt32?, UInt32?, String) -> Void
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var keyWindow: NSWindow?
    private var finished = false

    init(completion: @escaping (UInt32?, UInt32?, String) -> Void) {
        self.completion = completion
    }

    func start() {
        keyWindow = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.finish(keyCode: nil, modifiers: nil, reason: "Cancelled.")
            }
        })
        if let keyWindow {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: keyWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.finish(keyCode: nil, modifiers: nil, reason: "Cancelled.")
                }
            })
        }
    }

    func invalidate() {
        teardown()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if Int(event.keyCode) == kVK_Escape {
            finish(keyCode: nil, modifiers: nil, reason: "Cancelled.")
            return nil
        }

        let requiredMask: NSEvent.ModifierFlags = [.command, .option, .control]
        let active = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection(requiredMask)
        if active.isEmpty {
            return event
        }

        let modifiers = HotkeyRecorder.carbonModifiers(from: event.modifierFlags)
        let keyCode = UInt32(event.keyCode)
        if HotkeyRecorder.isReservedCombo(keyCode: keyCode, modifiers: modifiers) {
            finish(
                keyCode: nil,
                modifiers: nil,
                reason: "That combination conflicts with a common system shortcut."
            )
            return event
        }

        let display = HotkeyRecorder.displayString(keyCode: keyCode, modifiers: modifiers)
        finish(keyCode: keyCode, modifiers: modifiers, reason: display)
        return nil
    }

    private func finish(keyCode: UInt32?, modifiers: UInt32?, reason: String) {
        guard !finished else { return }
        finished = true
        teardown()
        completion(keyCode, modifiers, reason)
    }

    private func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        keyWindow = nil
        if HotkeyRecorder.currentSession === self {
            HotkeyRecorder.currentSession = nil
        }
    }
}
