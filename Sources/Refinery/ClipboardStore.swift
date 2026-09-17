import AppKit

/// Owns the clipboard read/write around a polish run.
public enum ClipboardStore {
    /// Reads the current pasteboard string, whatever it is.
    public static func read() -> String? {
        let pasteboard = NSPasteboard.general
        guard let content = pasteboard.string(forType: .string) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Writes the polished text to the clipboard.
    @discardableResult
    public static func write(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

enum ClipboardError: LocalizedError {
    case writeFailed

    var errorDescription: String? {
        "Could not write the polished text to the clipboard."
    }
}
