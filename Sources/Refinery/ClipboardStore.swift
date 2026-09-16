import AppKit

/// Owns the clipboard read/write around a polish run.
enum ClipboardStore {
    /// The maximum age of clipboard contents we treat as "what the user copied last".
    static let readWindow: TimeInterval = 30

    /// Reads the current pasteboard string, whatever it is.
    static func read() -> String? {
        let pasteboard = NSPasteboard.general
        guard let content = pasteboard.string(forType: .string) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Writes the polished text to the clipboard.
    static func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
