import AppKit
import ApplicationServices

/// Reads the current text selection from the frontmost app via the
/// Accessibility API (AXUIElement).
enum SelectionReader {
    /// The result of reading the current selection.
    enum Outcome {
        /// Non-empty selected text read from the focused element.
        case selected(String)
        /// The focused element resolved but carries no selection.
        case noSelection
        /// No focused element answered, or the focused app failed the query.
        case unreadable(String)
    }

    /// AX queries can fail transiently with `kAXErrorCannotComplete` while
    /// the frontmost app is still processing the keyboard event that fired
    /// the hotkey; a short settle-and-retry clears them.
    private static let settleAttempts = 3
    private static let settleInterval: TimeInterval = 0.08

    /// Reads the selected text of the element that would receive keystrokes.
    ///
    /// The focused element is resolved by asking the frontmost application
    /// directly (`NSWorkspace` pid -> `AXUIElementCreateApplication`), with
    /// the system-wide focused element as fallback: resolving through the
    /// system-wide element can fail with `cannotComplete` while the event
    /// loop settles, while the pid-addressed query answers in every
    /// context.
    static func readSelection() -> Outcome {
        guard let element = resolveFocusedElement() else {
            return .unreadable("no focused element responded")
        }
        return readSelection(from: element)
    }

    /// Reads the selection of a resolved element, retrying transient
    /// failures a few times so a busy frontmost app can settle.
    static func readSelection(from element: AXUIElement) -> Outcome {
        for attempt in 1...settleAttempts {
            if let outcome = attemptRead(from: element) {
                return outcome
            }
            if attempt < settleAttempts {
                Thread.sleep(forTimeInterval: settleInterval)
            }
        }
        return .unreadable("the focused app did not answer the accessibility query")
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

    // MARK: Focused-element resolution

    private static func resolveFocusedElement() -> AXUIElement? {
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            let application = AXUIElementCreateApplication(frontmost.processIdentifier)
            if let element = focusedElement(of: application) {
                return element
            }
        }
        let systemWide = AXUIElementCreateSystemWide()
        return focusedElement(of: systemWide)
    }

    /// Queries the focused element of `owner`, retrying transient failures.
    private static func focusedElement(of owner: AXUIElement) -> AXUIElement? {
        for attempt in 1...settleAttempts {
            var focused: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                owner,
                kAXFocusedUIElementAttribute as CFString,
                &focused
            )
            if result == .success, let focused,
               CFGetTypeID(focused) == AXUIElementGetTypeID() {
                return (focused as! AXUIElement)
            }
            if !isRetriable(result) { return nil }
            if attempt < settleAttempts {
                Thread.sleep(forTimeInterval: settleInterval)
            }
        }
        return nil
    }

    // MARK: Selection reads

    /// One read attempt. Returns nil when a transient failure should be retried.
    private static func attemptRead(from element: AXUIElement) -> Outcome? {
        var selected: CFTypeRef?
        let selectedResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selected
        )
        if selectedResult == .success {
            let text = (selected as? String) ?? ""
            return text.isEmpty ? .noSelection : .selected(text)
        }
        guard isRetriable(selectedResult) else {
            return selectionFromRange(of: element)
        }
        return nil
    }

    /// Fallback path: the selected text range applied to the element's full value.
    private static func selectionFromRange(of element: AXUIElement) -> Outcome {
        guard let selectedRange = rangeValue(element, kAXSelectedTextRangeAttribute as CFString) else {
            return .noSelection
        }
        var value: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        )
        guard valueResult == .success, let value,
              AXUIElementGetTypeID() != CFGetTypeID(value) else {
            return .noSelection
        }
        if let text = value as? String {
            return slice(text, selectedRange)
        }
        if let attributed = value as? NSAttributedString {
            return slice(attributed.string, selectedRange)
        }
        return .noSelection
    }

    static func slice(_ text: String, _ range: CFRange) -> Outcome {
        let nsRange = NSRange(location: range.location, length: range.length)
        guard let fastRange = Range(nsRange, in: text) else {
            return .noSelection
        }
        let selected = String(text[fastRange])
        return selected.isEmpty ? .noSelection : .selected(selected)
    }

    static func isRetriable(_ error: AXError) -> Bool {
        switch error {
        case .attributeUnsupported, .noValue, .invalidUIElement, .success:
            return false
        default:
            return true
        }
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
