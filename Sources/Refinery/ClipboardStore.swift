import AppKit

protocol PasteboardAccess: AnyObject {
    var pasteboardItems: [NSPasteboardItem]? { get }

    @discardableResult
    func clearContents() -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: PasteboardAccess {}

/// Owns clipboard writes after a polish run.
public enum ClipboardStore {
    /// Writes the polished text to the clipboard.
    @discardableResult
    public static func write(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        write(text, to: pasteboard as any PasteboardAccess)
    }

    static func write(_ text: String, to pasteboard: any PasteboardAccess) -> Bool {
        var previousItems: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type),
                      copy.setData(data, forType: type) else { return false }
            }
            previousItems.append(copy)
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            pasteboard.clearContents()
            _ = pasteboard.writeObjects(previousItems)
            return false
        }
        return true
    }
}

enum ClipboardError: LocalizedError {
    case writeFailed

    var errorDescription: String? {
        "Could not write the polished text to the clipboard."
    }
}
