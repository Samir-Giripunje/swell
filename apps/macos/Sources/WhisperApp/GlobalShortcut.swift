import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Carbon hot keys need no Accessibility or Input Monitoring permission,
/// and the key press is consumed, so the frontmost app never sees it.
final class GlobalShortcut {
    private static let signature = OSType(0x5357_454C) // "SWEL"
    nonisolated(unsafe) private static var nextID: UInt32 = 1

    private let id: UInt32
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: Int, modifiers: Int = 0, action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Every handler sees every hot key press, so each one answers only to its own ID.
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressedID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &pressedID
            )
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue()
            guard pressedID.signature == GlobalShortcut.signature, pressedID.id == shortcut.id else { return OSStatus(eventNotHandledErr) }
            shortcut.action()
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let registered = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &hotKey
        )
        guard installed == noErr, registered == noErr else { return nil }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
