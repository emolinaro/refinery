import AppKit

protocol PasteboardAccess: AnyObject {
    var pasteboardItems: [NSPasteboardItem]? { get }
    var changeCount: Int { get }

    @discardableResult
    func clearContents() -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
    func string(forType dataType: NSPasteboard.PasteboardType) -> String?
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: PasteboardAccess {}

/// Owns clipboard writes after a polish run.
public enum ClipboardStore {
    struct Snapshot {
        fileprivate let items: [NSPasteboardItem]
    }

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
        let capturedSnapshot: Snapshot
        switch snapshot(of: pasteboard) {
        case .success(let captured):
            capturedSnapshot = captured
        case .failure(let error):
            return .failure(error)
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            switch restore(capturedSnapshot, to: pasteboard) {
            case .success:
                return .failure(.writeFailed)
            case .failure:
                return .failure(.restorationFailed)
            }
        }
        return .success(())
    }

    static func snapshot(
        of pasteboard: any PasteboardAccess
    ) -> Result<Snapshot, ClipboardError> {
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
        return .success(Snapshot(items: previousItems))
    }

    static func restore(
        _ snapshot: Snapshot,
        to pasteboard: any PasteboardAccess
    ) -> Result<Void, ClipboardError> {
        pasteboard.clearContents()
        guard pasteboard.writeObjects(snapshot.items) else {
            return .failure(.restorationFailed)
        }
        return .success(())
    }
}

enum ClipboardError: LocalizedError, Equatable, Sendable {
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
