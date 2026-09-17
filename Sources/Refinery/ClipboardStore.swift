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
        switch writeResult(text, to: pasteboard) {
        case .success:
            return true
        case .failure:
            return false
        }
    }

    static func writeResult(
        _ text: String,
        to pasteboard: any PasteboardAccess
    ) -> Result<Void, ClipboardError> {
        guard let currentItems = pasteboard.pasteboardItems else {
            return .failure(.snapshotFailed)
        }
        var previousItems: [NSPasteboardItem] = []
        for item in currentItems {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type),
                      copy.setData(data, forType: type) else { return .failure(.snapshotFailed) }
            }
            previousItems.append(copy)
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            pasteboard.clearContents()
            guard pasteboard.writeObjects(previousItems) else {
                return .failure(.restorationFailed)
            }
            return .failure(.writeFailed)
        }
        return .success(())
    }
}

enum ClipboardError: LocalizedError, Equatable {
    case snapshotFailed
    case writeFailed
    case restorationFailed

    var errorDescription: String? {
        switch self {
        case .snapshotFailed:
            return "Could not safely read the current clipboard, so it was left unchanged."
        case .writeFailed:
            return "Could not write the polished text to the clipboard."
        case .restorationFailed:
            return "Could not write the polished text or restore the previous clipboard contents."
        }
    }
}
