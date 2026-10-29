import AppKit

enum Hotkey: String, CaseIterable, Identifiable {
    case rightCommand
    case rightOption

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightCommand: "Right ⌘ Command"
        case .rightOption: "Right ⌥ Option"
        }
    }

    var shortTitle: String {
        switch self {
        case .rightCommand: "right ⌘"
        case .rightOption: "right ⌥"
        }
    }

    fileprivate var keyCode: UInt16 {
        switch self {
        case .rightCommand: 54
        case .rightOption: 61
        }
    }

    // Device-dependent modifier bits (NX_DEVICERCMDKEYMASK / NX_DEVICERALTKEYMASK)
    // tell the right-hand key apart from the left-hand one.
    fileprivate var deviceMask: UInt {
        switch self {
        case .rightCommand: 0x10
        case .rightOption: 0x40
        }
    }
}

final class HotkeyMonitor {
    var hotkey: Hotkey = .rightCommand
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: ((String) -> Void)?

    private var monitors: [Any] = []
    private var isHeld = false

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        isHeld = false
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged, event.keyCode == hotkey.keyCode else {
            cancelIfHeld(by: event)
            return
        }
        let isDown = event.modifierFlags.rawValue & hotkey.deviceMask != 0
        if isDown, !isHeld {
            isHeld = true
            onPress?()
        } else if !isDown, isHeld {
            isHeld = false
            onRelease?()
        }
    }

    private func cancelIfHeld(by event: NSEvent) {
        guard isHeld else { return }
        isHeld = false
        onCancel?("type=\(event.type.rawValue) keyCode=\(event.keyCode) flags=0x\(String(event.modifierFlags.rawValue, radix: 16))")
    }
}
