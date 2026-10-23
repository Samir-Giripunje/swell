import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private static let transcribingFrameInterval: TimeInterval = 0.35

    private let state: AppState
    private let openMainWindow: () -> Void
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()
    private var animationTimer: Timer?
    private var animationFrame = 0

    private let idleImage = StatusItemController.symbol("waveform")
    private let recordingImage = StatusItemController.symbol("mic.fill", tint: .systemRed)
    private let transcribingImages = ["text.bubble", "text.bubble.fill"].map { StatusItemController.symbol($0) }

    init(state: AppState, openMainWindow: @escaping () -> Void) {
        self.state = state
        self.openMainWindow = openMainWindow
        super.init()

        state.$loadedModelID
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] isLoaded in self?.setVisible(isLoaded) }
            .store(in: &subscriptions)

        state.$phase
            .removeDuplicates()
            .sink { [weak self] phase in self?.showIcon(for: phase) }
            .store(in: &subscriptions)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let hint = NSMenuItem(title: "Hold \(state.hotkey.shortTitle) to dictate", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        menu.addItem(item("Open Swell…", action: #selector(openWindow)))
        menu.addItem(item("Load model when the app starts", action: #selector(toggleLoadAtStart), isOn: state.loadModelAtStart))
        menu.addItem(item("Launch at login", action: #selector(toggleLaunchAtLogin), isOn: state.isLaunchAtLoginEnabled))
        menu.addItem(.separator())

        let unload = item("Unload model", action: #selector(unloadModel))
        unload.isEnabled = state.phase == .idle
        menu.addItem(unload)
        menu.addItem(item("Quit Swell", action: #selector(quit), key: "q"))
    }

    private func setVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "WhisperStatusItem"
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            statusItem = item
            showIcon(for: state.phase)
        } else if !visible, let item = statusItem {
            stopAnimation()
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func showIcon(for phase: DictationPhase) {
        stopAnimation()
        switch phase {
        case .idle: statusItem?.button?.image = idleImage
        case .recording: statusItem?.button?.image = recordingImage
        case .transcribing: startTranscribingAnimation()
        }
    }

    private func startTranscribingAnimation() {
        animationFrame = 0
        statusItem?.button?.image = transcribingImages[0]
        let timer = Timer(timeInterval: Self.transcribingFrameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceAnimationFrame() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func advanceAnimationFrame() {
        animationFrame = (animationFrame + 1) % transcribingImages.count
        statusItem?.button?.image = transcribingImages[animationFrame]
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func item(_ title: String, action: Selector, isOn: Bool? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let isOn { item.state = isOn ? .on : .off }
        return item
    }

    @objc private func openWindow() { openMainWindow() }
    @objc private func toggleLoadAtStart() { state.loadModelAtStart.toggle() }
    @objc private func toggleLaunchAtLogin() { state.setLaunchAtLogin(!state.isLaunchAtLoginEnabled) }
    @objc private func unloadModel() { Task { await state.unloadModel() } }
    @objc private func quit() { NSApp.terminate(nil) }

    private static func symbol(_ name: String, tint: NSColor? = nil) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Swell") ?? NSImage()
        guard let tint else {
            image.isTemplate = true
            return image
        }
        let tinted = image.withSymbolConfiguration(.init(paletteColors: [tint])) ?? image
        tinted.isTemplate = false
        return tinted
    }
}
