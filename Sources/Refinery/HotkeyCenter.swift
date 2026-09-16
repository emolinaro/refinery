import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut that fires with text selected in any app.
///
/// Uses Carbon's `RegisterEventHotKey`, still the supported way to get a
/// global hotkey on macOS without a helper process or sandbox entitlements.
@MainActor
final class HotkeyCenter {
    /// Called on the main thread whenever the registered hotkey fires.
    var onTrigger: (() -> Void)?


    private var hotkeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var signature: UInt32 = 0
    private var currentKeyCode: UInt32 = 0
    private var currentModifiers: UInt32 = 0

    init() {}

    /// Registers the hotkey. Replaces any previously registered one.
    /// - Parameters:
    ///   - keyCode: Carbon virtual keycode.
    ///   - modifiers: Carbon modifier mask (cmdKey, optionKey, ...).
    /// - Returns: true when registration succeeded.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()

        signature = Self.fourCC("RFSH")
        let hotkeyID = EventHotKeyID(signature: signature, id: 1)
        currentKeyCode = keyCode
        currentModifiers = modifiers

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotkeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let hotkeyRef = ref else {
            return false
        }
        self.hotkeyRef = hotkeyRef

        var handler: EventHandlerRef?
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotkeyID
            )
            if status == noErr, hotkeyID.signature == HotkeyCenter.signatureValue {
                let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { center.fire() }
                }
            }
            return noErr
        }
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard installStatus == noErr else {
            unregister()
            return false
        }
        eventHandler = handler
        return true
    }

    /// Removes the current registration, if any.
    func unregister() {
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }
        currentKeyCode = 0
        currentModifiers = 0
    }

    /// Fires the trigger on the main thread.
    private func fire() {
        onTrigger?()
    }

    fileprivate static let signatureValue: UInt32 = fourCC("RFSH")

    private static func fourCC(_ string: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in string.utf8.prefix(4) {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }
}
