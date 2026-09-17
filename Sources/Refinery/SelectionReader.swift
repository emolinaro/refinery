import AppKit

/// Reads the current text selection from the frontmost app via the
/// Accessibility API (AXUIElement).
enum SelectionReader {
    /// Returns the selected text of the system-wide focused element.
    static func readSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard focusResult == .success, let element = focusedElement else {
            return nil
        }
        let axElement = element as! AXUIElement

        // Preferred path: the element's own selection.
        if let selected = stringValue(axElement, kAXSelectedTextAttribute as CFString) {
            return selected
        }

        // Fallback path: selected text range applied to the element's full value.
        if let selectedRange = rangeValue(axElement, kAXSelectedTextRangeAttribute as CFString) {
            var value: CFTypeRef?
            let valueResult = AXUIElementCopyAttributeValue(
                axElement,
                kAXValueAttribute as CFString,
                &value
            )
            if valueResult == .success, let value,
               AXUIElementGetTypeID() != CFGetTypeID(value) {
                if let text = value as? String {
                    let nsRange = NSRange(location: selectedRange.location, length: selectedRange.length)
                    if let fastRange = Range(nsRange, in: text) {
                        return String(text[fastRange])
                    }
                } else if let attributed = value as? NSAttributedString {
                    let nsRange = NSRange(location: selectedRange.location, length: selectedRange.length)
                    if let fastRange = Range(nsRange, in: attributed.string) {
                        return String(attributed.string[fastRange])
                    }
                }
            }
        }

        return nil
    }

    /// True when the app has the accessibility permission needed to read
    /// selections from other apps.
    static func isAccessibilityEnabled() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Presents the system accessibility permission prompt (call once, on first run).
    static func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func stringValue(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }
        return value as? String
    }

    private static func rangeValue(_ element: AXUIElement, _ attribute: CFString) -> CFRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }
        // CFRange comes back as an AXValue; convert.
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }
}
