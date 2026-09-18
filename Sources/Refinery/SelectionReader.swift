import AppKit
import ApplicationServices

/// Reads the current text selection from the frontmost app via the
/// Accessibility API (AXUIElement).
enum SelectionReader {
    typealias AttributeReader = (AXUIElement, CFString) -> (AXError, CFTypeRef?)
    typealias ProcessIdentifierReader = (AXUIElement) -> pid_t?

    struct Context: @unchecked Sendable {
        let processIdentifier: pid_t
        fileprivate let element: AXUIElement
    }

    /// The result of reading the current selection.
    enum Outcome: Equatable, Sendable {
        /// Non-empty selected text read from the focused element.
        case selected(String)
        /// The focused element resolved but carries no selection.
        case noSelection
        /// No focused element answered, or the focused app failed the query.
        case unreadable
    }

    /// AX queries can fail transiently with `kAXErrorCannotComplete` while
    /// the frontmost app is still processing the keyboard event that fired
    /// the hotkey; a short settle-and-retry clears them.
    private static let settleAttempts = 3
    private static let settleInterval: TimeInterval = 0.08

    static func frontmostApplicationPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static func captureContext(for processIdentifier: pid_t) -> Context? {
        captureContext(
            for: processIdentifier,
            elementResolver: resolveFocusedElement,
            processIdentifierReader: processIdentifierOfElement
        )
    }

    static func captureContext(
        for processIdentifier: pid_t,
        elementResolver: (pid_t) -> AXUIElement?,
        processIdentifierReader: ProcessIdentifierReader
    ) -> Context? {
        guard let element = elementResolver(processIdentifier),
              processIdentifierReader(element) == processIdentifier else {
            return nil
        }
        return Context(processIdentifier: processIdentifier, element: element)
    }

    static func readSelection(from context: Context) -> Outcome {
        readSelection(
            from: context,
            elementResolver: resolveFocusedElement,
            attributeReader: copyAttributeValue,
            sleep: { Thread.sleep(forTimeInterval: $0) }
        )
    }

    static func readSelection(
        from context: Context,
        elementResolver: (pid_t) -> AXUIElement?,
        attributeReader: AttributeReader,
        sleep: (TimeInterval) -> Void
    ) -> Outcome {
        for attempt in 1...settleAttempts {
            guard let focusedElement = elementResolver(context.processIdentifier),
                  CFEqual(focusedElement, context.element) else {
                return .unreadable
            }
            if let outcome = attemptRead(from: context.element, attributeReader: attributeReader) {
                return outcome
            }
            if attempt < settleAttempts {
                sleep(settleInterval)
            }
        }
        return .unreadable
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

    private static func resolveFocusedElement(for processIdentifier: pid_t) -> AXUIElement? {
        resolveFocusedElement(
            for: processIdentifier,
            applicationElement: AXUIElementCreateApplication,
            systemWideElement: AXUIElementCreateSystemWide,
            attributeReader: copyAttributeValue,
            processIdentifierReader: processIdentifierOfElement
        )
    }

    static func resolveFocusedElement(
        for processIdentifier: pid_t,
        applicationElement: (pid_t) -> AXUIElement,
        systemWideElement: () -> AXUIElement,
        attributeReader: AttributeReader,
        processIdentifierReader: ProcessIdentifierReader
    ) -> AXUIElement? {
        let application = applicationElement(processIdentifier)
        if let element = focusedElement(
            of: application,
            expectedProcessIdentifier: processIdentifier,
            attributeReader: attributeReader,
            processIdentifierReader: processIdentifierReader
        ) {
            return element
        }
        return focusedElement(
            of: systemWideElement(),
            expectedProcessIdentifier: processIdentifier,
            attributeReader: attributeReader,
            processIdentifierReader: processIdentifierReader
        )
    }

    private static func focusedElement(
        of owner: AXUIElement,
        expectedProcessIdentifier: pid_t,
        attributeReader: AttributeReader,
        processIdentifierReader: ProcessIdentifierReader
    ) -> AXUIElement? {
        let (result, focused) = attributeReader(
            owner,
            kAXFocusedUIElementAttribute as CFString
        )
        guard result == .success, let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = focused as! AXUIElement
        guard processIdentifierReader(element) == expectedProcessIdentifier else {
            return nil
        }
        return element
    }

    // MARK: Selection reads

    /// One read attempt. Returns nil when a transient failure should be retried.
    private static func attemptRead(
        from element: AXUIElement,
        attributeReader: AttributeReader
    ) -> Outcome? {
        let (selectedResult, selected) = attributeReader(
            element,
            kAXSelectedTextAttribute as CFString
        )
        if selectedResult == .success {
            if let text = selected as? String {
                return text.isEmpty ? .noSelection : .selected(text)
            }
            if let attributed = selected as? NSAttributedString {
                return attributed.string.isEmpty ? .noSelection : .selected(attributed.string)
            }
            return .unreadable
        }
        if selectedResult == .attributeUnsupported || selectedResult == .noValue {
            return selectionFromRange(of: element, attributeReader: attributeReader)
        }
        return isRetriable(selectedResult) ? nil : .unreadable
    }

    /// Fallback path: the selected text range applied to the element's full value.
    private static func selectionFromRange(
        of element: AXUIElement,
        attributeReader: AttributeReader
    ) -> Outcome? {
        let (rangeResult, rangeValue) = attributeReader(
            element,
            kAXSelectedTextRangeAttribute as CFString
        )
        guard rangeResult == .success else {
            return isRetriable(rangeResult) ? nil : .unreadable
        }
        guard let selectedRange = range(from: rangeValue) else {
            return .unreadable
        }
        guard selectedRange.location >= 0, selectedRange.length >= 0 else {
            return .unreadable
        }
        guard selectedRange.length > 0 else {
            return .noSelection
        }
        let (valueResult, value) = attributeReader(
            element,
            kAXValueAttribute as CFString
        )
        guard valueResult == .success else {
            return isRetriable(valueResult) ? nil : .unreadable
        }
        guard let value else {
            return .unreadable
        }
        if let text = value as? String {
            return slice(text, selectedRange)
        }
        if let attributed = value as? NSAttributedString {
            return slice(attributed.string, selectedRange)
        }
        return .unreadable
    }

    static func slice(_ text: String, _ range: CFRange) -> Outcome {
        guard range.location >= 0, range.length >= 0 else {
            return .unreadable
        }
        guard range.length > 0 else {
            return .noSelection
        }
        let nsRange = NSRange(location: range.location, length: range.length)
        guard let fastRange = Range(nsRange, in: text) else {
            return .unreadable
        }
        let selected = String(text[fastRange])
        return selected.isEmpty ? .noSelection : .selected(selected)
    }

    static func isRetriable(_ error: AXError) -> Bool {
        error == .cannotComplete || error == .invalidUIElement
    }

    private static func copyAttributeValue(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        return (result, value)
    }

    private static func processIdentifierOfElement(_ element: AXUIElement) -> pid_t? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success else {
            return nil
        }
        return processIdentifier
    }

    private static func range(from value: CFTypeRef?) -> CFRange? {
        guard let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }
}
