import AppKit

enum TextPaster {
    private static let vKeyCode: CGKeyCode = 9
    private static let cKeyCode: CGKeyCode = 8
    private static let copyWaitSteps = 20
    // A busy target app (e.g. an Electron app mid-render) can read the clipboard
    // well after ⌘V is posted; restoring too early pastes the old clipboard.
    private static let clipboardRestoreDelay: TimeInterval = 2

    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedItems = copyItems(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let transcriptChangeCount = pasteboard.changeCount
        sendCommand(vKeyCode)

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

    /// The frontmost app's selection, copied with ⌘C, for apps that don't expose it to Accessibility
    /// (Slack, Chrome and other web views). The clipboard is put back afterwards.
    @MainActor
    static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let savedItems = copyItems(from: pasteboard)
        let before = pasteboard.changeCount
        sendCommand(cKeyCode)
        for _ in 0..<copyWaitSteps where pasteboard.changeCount == before {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
        return text
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

    // The flags are set explicitly, so modifiers the user is still holding (such as ⌃⌥ from a shortcut) don't leak in.
    private static func sendCommand(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isKeyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isKeyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
