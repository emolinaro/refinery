import AppKit
import ApplicationServices

/// Reads the current text selection from the frontmost app via the
/// Accessibility API (AXUIElement), routing apps that render text without AX
/// backing to the guarded clipboard probe in ClipboardSelectionProbe.
enum SelectionReader {
    typealias AttributeReader = (AXUIElement, CFString) -> (AXError, CFTypeRef?)
    typealias ChildrenReader = (AXUIElement) -> (AXError, [AXUIElement]?)
    typealias ProcessIdentifierReader = (AXUIElement) -> pid_t?

    /// The result of reading the current selection.
    enum Outcome: Equatable, Sendable {
        /// Non-empty selected text read from the focused element.
        case selected(String)
        /// Non-empty text the clipboard probe read and restored; the polished
        /// result must replace the pasteboard only while its change count
        /// still equals `expectedChangeCount`, so any newer copy is preserved
        /// instead of overwritten.
        case clipboardSelection(String, expectedChangeCount: Int)
        /// The focused element resolved but carries no selection.
        case noSelection
        /// The bound focus or selection changed, or the focused app failed the
        /// query.
        case unreadable
        /// A clipboard probe changed the pasteboard but could not restore it,
        /// or could not safely snapshot it before probing.
        case clipboardFailure(ClipboardError)
    }

    struct Context: @unchecked Sendable {
        let processIdentifier: pid_t
        let selection: Outcome
        fileprivate let element: AXUIElement
    }

    struct ClipboardContext: @unchecked Sendable {
        let processIdentifier: pid_t
        let element: AXUIElement
    }

    enum ElementResolution {
        case resolved(AXUIElement)
        case failed(AXError)
    }

    enum Capture {
        case accessibility(Context)
        case clipboardProbe(ClipboardContext)
        case unavailable
    }

    /// After the hotkey-time context is captured, validation queries can fail
    /// transiently while the frontmost app is still processing the event. A
    /// short settle-and-retry clears supported transient errors without
    /// rebinding the original selection.
    private static let settleAttempts = 3
    private static let settleInterval: TimeInterval = 0.08

    static func frontmostApplicationPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static func capture(for processIdentifier: pid_t) -> Capture {
        capture(
            for: processIdentifier,
            elementResolver: resolveFocusedElement,
            processIdentifierReader: processIdentifierOfElement,
            attributeReader: copyAttributeValue
        )
    }

    static func capture(
        for processIdentifier: pid_t,
        elementResolver: (pid_t) -> ElementResolution,
        processIdentifierReader: ProcessIdentifierReader,
        attributeReader: AttributeReader
    ) -> Capture {
        guard case .resolved(let element) = elementResolver(processIdentifier),
              processIdentifierReader(element) == processIdentifier,
              let selection = attemptRead(from: element, attributeReader: attributeReader) else {
            return .unavailable
        }
        if selection != .unreadable {
            return .accessibility(Context(
                processIdentifier: processIdentifier,
                selection: selection,
                element: element
            ))
        }
        return .clipboardProbe(ClipboardContext(
            processIdentifier: processIdentifier,
            element: element
        ))
    }

    static func applicationLacksTextSurfaces(for processIdentifier: pid_t) -> Bool {
        applicationLacksTextSurfaces(
            for: processIdentifier,
            processIdentifierReader: processIdentifierOfElement,
            attributeReader: copyAttributeValue,
            childrenReader: copyChildren,
            applicationElement: AXUIElementCreateApplication
        )
    }

    static func applicationLacksTextSurfaces(
        for processIdentifier: pid_t,
        processIdentifierReader: ProcessIdentifierReader,
        attributeReader: AttributeReader,
        childrenReader: ChildrenReader,
        applicationElement: (pid_t) -> AXUIElement
    ) -> Bool {
        let application = applicationElement(processIdentifier)
        guard processIdentifierReader(application) == processIdentifier else {
            return false
        }
        return textCapability(
            rootedAt: application,
            attributeReader: attributeReader,
            childrenReader: childrenReader
        ) == .absent
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
        elementResolver: (pid_t) -> ElementResolution,
        attributeReader: AttributeReader,
        sleep: (TimeInterval) -> Void
    ) -> Outcome {
        for attempt in 1...settleAttempts {
            switch elementResolver(context.processIdentifier) {
            case .resolved(let focusedElement):
                guard CFEqual(focusedElement, context.element) else {
                    return .unreadable
                }
                if let outcome = attemptRead(from: context.element, attributeReader: attributeReader) {
                    return outcome == context.selection ? context.selection : .unreadable
                }
            case .failed(let error):
                guard isRetriable(error) else { return .unreadable }
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

    /// Presents the system accessibility permission prompt. Only AppModel's
    /// once-per-launch gate may call this; callers that just need to know
    /// whether the grant is held must use `isAccessibilityEnabled()` so the
    /// system never re-opens System Settings on every hotkey press.
    static func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Focused-element resolution

    static func resolveFocusedElement(for processIdentifier: pid_t) -> ElementResolution {
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
    ) -> ElementResolution {
        let application = applicationElement(processIdentifier)
        let applicationResolution = focusedElement(
            of: application,
            expectedProcessIdentifier: processIdentifier,
            attributeReader: attributeReader,
            processIdentifierReader: processIdentifierReader
        )
        if case .resolved = applicationResolution {
            return applicationResolution
        }
        let systemWideResolution = focusedElement(
            of: systemWideElement(),
            expectedProcessIdentifier: processIdentifier,
            attributeReader: attributeReader,
            processIdentifierReader: processIdentifierReader
        )
        if case .resolved = systemWideResolution {
            return systemWideResolution
        }
        if case .failed(let error) = systemWideResolution, isRetriable(error) {
            return systemWideResolution
        }
        if case .failed(let error) = applicationResolution, isRetriable(error) {
            return applicationResolution
        }
        return systemWideResolution
    }

    private static func focusedElement(
        of owner: AXUIElement,
        expectedProcessIdentifier: pid_t,
        attributeReader: AttributeReader,
        processIdentifierReader: ProcessIdentifierReader
    ) -> ElementResolution {
        let (result, focused) = attributeReader(
            owner,
            kAXFocusedUIElementAttribute as CFString
        )
        guard result == .success else {
            return .failed(result)
        }
        guard let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return .failed(.failure)
        }
        let element = focused as! AXUIElement
        guard processIdentifierReader(element) == expectedProcessIdentifier else {
            return .failed(.failure)
        }
        return .resolved(element)
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

    private enum TextCapability {
        case present
        case absent
        case unknown
    }

    /// Proves that the application subtree has no AX-backed text surface. Any
    /// unreadable node or an unexpectedly large tree fails closed so the
    /// clipboard fallback never runs merely because AX had a transient error.
    /// The menu bar is chrome, not a text surface: a custom-rendered editor can
    /// expose a fully standard menu bar while its content subtree is empty or
    /// absent, so the walk does not descend into menu bars and a menu-bar-only
    /// tree proves that no text surface exists instead of degrading to unknown.
    private static func textCapability(
        rootedAt root: AXUIElement,
        attributeReader: AttributeReader,
        childrenReader: ChildrenReader
    ) -> TextCapability {
        let maximumElements = 512
        var pending = [root]
        var visited = 0

        while let element = pending.first {
            pending.removeFirst()
            visited += 1
            guard visited <= maximumElements else { return .unknown }

            let (roleResult, roleValue) = attributeReader(
                element,
                kAXRoleAttribute as CFString
            )
            guard roleResult == .success, let role = roleValue as? String else {
                return .unknown
            }
            if role == kAXTextAreaRole || role == kAXTextFieldRole || role == "AXWebArea" {
                return .present
            }
            if role == kAXMenuBarRole {
                continue
            }

            let (childrenResult, children) = childrenReader(element)
            switch childrenResult {
            case .success:
                guard let children else { return .unknown }
                pending.append(contentsOf: children)
            case .attributeUnsupported, .noValue:
                break
            default:
                return .unknown
            }
        }
        return .absent
    }

    private static func copyAttributeValue(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        return (result, value)
    }

    private static func copyChildren(_ element: AXUIElement) -> (AXError, [AXUIElement]?) {
        let (result, value) = copyAttributeValue(
            element,
            kAXChildrenAttribute as CFString
        )
        if result == .attributeUnsupported || result == .noValue {
            return (result, [])
        }
        guard result == .success, let children = value as? [AXUIElement] else {
            return (result == .success ? .failure : result, nil)
        }
        return (.success, children)
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
