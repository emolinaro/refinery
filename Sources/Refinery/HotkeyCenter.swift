import AppKit
import Carbon.HIToolbox

@MainActor
protocol HotkeyManaging: AnyObject {
    var onTrigger: (() -> Void)? { get set }
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool
    func suspend()
}

/// A system-wide keyboard shortcut that fires with text selected in any app.
///
/// Uses Carbon's `RegisterEventHotKey`, still the supported way to get a
/// global hotkey on macOS without a helper process or sandbox entitlements.
@MainActor
final class HotkeyCenter: HotkeyManaging {
    /// Called on the main thread whenever the registered hotkey fires.
    var onTrigger: (() -> Void)?

    private var hotkeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var currentKeyCode: UInt32 = 0
    private var currentModifiers: UInt32 = 0
    private var isTriggerSuppressed = false

    init() {}

    /// Registers the hotkey, replacing any previously registered one. The
    /// previous registration is kept when the new combination cannot be
    /// registered (e.g. it is owned by another app).
    /// - Parameters:
    ///   - keyCode: Carbon virtual keycode.
    ///   - modifiers: Carbon modifier mask (cmdKey, optionKey, ...).
    /// - Returns: true when registration succeeded.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        if hotkeyRef != nil, keyCode == currentKeyCode, modifiers == currentModifiers {
            isTriggerSuppressed = false
            return true
        }

        let hotkeyID = EventHotKeyID(signature: Self.signatureValue, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotkeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let newRef = ref else {
            return false
        }

        guard installHandlerIfNeeded() else {
            UnregisterEventHotKey(newRef)
            return false
        }

        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
        }
        hotkeyRef = newRef
        currentKeyCode = keyCode
        currentModifiers = modifiers
        isTriggerSuppressed = false
        return true
    }

    func suspend() {
        isTriggerSuppressed = true
    }

    /// Fires the trigger on the main thread.
    private func fire() {
        guard !isTriggerSuppressed else { return }
        onTrigger?()
    }

    private func installHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }
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
        guard installStatus == noErr else { return false }
        eventHandler = handler
        return true
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
