import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Captures a global hotkey by listening for the next key press with modifiers.
///
/// A local event monitor (not a global one) is enough because the settings
/// window is key while recording; the user is told to press the combination.
enum HotkeyRecorder {
    /// Runs a recording session on the main thread.
    /// - Parameter completion: called with (keyCode, modifiers, displayString)
    ///   on success, or (nil, nil, reason) when recording was cancelled.
    static func start(completion: @escaping (UInt32?, UInt32?, String) -> Void) {
        var monitor: Any?
        let closure: (NSEvent) -> NSEvent? = { event in
            guard event.type == .keyDown else { return event }
            if let monitor { NSEvent.removeMonitor(monitor) }
            let modifiers = carbonModifiers(from: event.modifierFlags)
            let keyCode = UInt32(event.keyCode)
            // Require at least one modifier other than shift.
            let requiredMask: NSEvent.ModifierFlags = [.command, .option, .control]
            let active = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .intersection(requiredMask)
            if active.isEmpty {
                completion(nil, nil, "Include ⌘, ⌥ or ⌃ in the shortcut.")
                return nil
            }
            let display = displayString(keyCode: keyCode, modifiers: modifiers)
            completion(keyCode, modifiers, display)
            return nil
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: closure)
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
