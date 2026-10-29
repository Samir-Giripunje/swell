import AppKit

enum TextPaster {
    private static let vKeyCode: CGKeyCode = 9
    // A busy target app (e.g. an Electron app mid-render) can read the clipboard
    // well after ⌘V is posted; restoring too early pastes the old clipboard.
    private static let clipboardRestoreDelay: TimeInterval = 2

    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedItems = copyItems(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let transcriptChangeCount = pasteboard.changeCount
        sendCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
            guard !savedItems.isEmpty, pasteboard.changeCount == transcriptChangeCount else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func copyItems(from pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isKeyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: isKeyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
