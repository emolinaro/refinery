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
    /// A full-fidelity copy of every current pasteboard representation,
    /// restored verbatim (after a failed write or a clipboard probe) so the
    /// user's clipboard is never silently lost. `stringRepresentation` is
    /// the pasteboard's combined string view (multi-item pasteboards join
    /// with newlines), which lets the probe reject a copy that only repeats
    /// what the user already had.
    struct Snapshot {
        fileprivate let items: [NSPasteboardItem]
        fileprivate let stringRepresentation: String?

        func containsString(_ text: String) -> Bool {
            stringRepresentation == text
                || items.contains { $0.string(forType: .string) == text }
        }

        func matches(_ pasteboard: any PasteboardAccess) -> Bool {
            guard let currentItems = pasteboard.pasteboardItems,
                  currentItems.count == items.count else {
                return false
            }
            for (expected, current) in zip(items, currentItems) {
                let expectedTypes = Set(expected.types.map(\.rawValue))
                let currentTypes = Set(current.types.map(\.rawValue))
                guard expectedTypes == currentTypes else { return false }
                for type in expected.types
                    where expected.data(forType: type) != current.data(forType: type) {
                    return false
                }
            }
            return true
        }

        fileprivate func makeItems() -> [NSPasteboardItem]? {
            var copies: [NSPasteboardItem] = []
            for item in items {
                let copy = NSPasteboardItem()
                for type in item.types {
                    guard let data = item.data(forType: type),
                          copy.setData(data, forType: type) else {
                        return nil
                    }
                }
                copies.append(copy)
            }
            return copies
        }
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
        to pasteboard: any PasteboardAccess,
        ifUnchangedSince expectedChangeCount: Int? = nil
    ) -> Result<Void, ClipboardError> {
        if let expectedChangeCount,
           pasteboard.changeCount != expectedChangeCount {
            return .failure(.clipboardChanged)
        }
        let capturedSnapshot: Snapshot
        switch snapshot(of: pasteboard) {
        case .success(let captured):
            capturedSnapshot = captured
        case .failure(let error):
            return .failure(error)
        }
        if let expectedChangeCount,
           pasteboard.changeCount != expectedChangeCount {
            return .failure(.clipboardChanged)
        }
        let writeChangeCount = pasteboard.clearContents()
        guard pasteboard.changeCount == writeChangeCount else {
            return .failure(.clipboardChanged)
        }
        guard pasteboard.setString(text, forType: .string) else {
            guard pasteboard.changeCount == writeChangeCount else {
                return .failure(.clipboardChanged)
            }
            switch restoreWithChangeCount(
                capturedSnapshot,
                to: pasteboard,
                ifUnchangedSince: writeChangeCount
            ) {
            case .success:
                return .failure(.writeFailed)
            case .failure(let error):
                return .failure(error == .clipboardChanged ? error : .restorationFailed)
            }
        }
        guard pasteboard.changeCount == writeChangeCount,
              pasteboard.string(forType: .string) == text else {
            return .failure(.clipboardChanged)
        }
        return .success(())
    }

    static func snapshot(
        of pasteboard: any PasteboardAccess
    ) -> Result<Snapshot, ClipboardError> {
        let stringRepresentation = pasteboard.string(forType: .string)
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
        return .success(Snapshot(
            items: previousItems,
            stringRepresentation: stringRepresentation
        ))
    }

    static func restoreWithChangeCount(
        _ snapshot: Snapshot,
        to pasteboard: any PasteboardAccess,
        ifUnchangedSince expectedChangeCount: Int
    ) -> Result<Int, ClipboardError> {
        guard let items = snapshot.makeItems() else {
            return .failure(.restorationFailed)
        }
        guard pasteboard.changeCount == expectedChangeCount else {
            return .failure(.clipboardChanged)
        }
        let restoredChangeCount = pasteboard.clearContents()
        guard pasteboard.changeCount == restoredChangeCount else {
            return .failure(.clipboardChanged)
        }
        guard pasteboard.writeObjects(items) else {
            return pasteboard.changeCount == restoredChangeCount
                ? .failure(.restorationFailed)
                : .failure(.clipboardChanged)
        }
        guard pasteboard.changeCount == restoredChangeCount else {
            return .failure(.clipboardChanged)
        }
        guard snapshot.matches(pasteboard) else {
            return pasteboard.changeCount == restoredChangeCount
                ? .failure(.restorationFailed)
                : .failure(.clipboardChanged)
        }
        guard pasteboard.changeCount == restoredChangeCount else {
            return .failure(.clipboardChanged)
        }
        return .success(restoredChangeCount)
    }
}

enum ClipboardError: LocalizedError, Equatable, Sendable {
    case snapshotFailed
    case probeFailed
    case selectionReadTimedOut
    case clipboardChanged
    case writeFailed
    case restorationFailed

    var errorDescription: String? {
        switch self {
        case .snapshotFailed:
            return "Could not safely read the current clipboard, so it was left unchanged."
        case .probeFailed:
            return "Could not safely prepare the clipboard to read the selected text."
        case .selectionReadTimedOut:
            return "The selection copy arrived too late, so the previous clipboard was restored. Try again."
        case .clipboardChanged:
            return "The clipboard changed during processing, so its newer contents were preserved."
        case .writeFailed:
            return "Could not write the polished text to the clipboard."
        case .restorationFailed:
            return "Could not write the polished text or restore the previous clipboard contents."
        }
    }
}
