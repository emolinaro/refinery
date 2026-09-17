import AppKit

/// Owns clipboard writes after a polish run.
public enum ClipboardStore {
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
