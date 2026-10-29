import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private static let transcribingFrameInterval: TimeInterval = 0.35

    private let state: AppState
    private let correction: CorrectionController
    private lazy var correctionPopover = makeCorrectionPopover()
    private let openMainWindow: () -> Void
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()
    private var animationTimer: Timer?
    private var animationFrame = 0

    private let idleImage = StatusItemController.symbol("waveform")
    private let recordingImage = StatusItemController.symbol("mic.fill", tint: .systemRed)
    private let transcribingImages = ["text.bubble", "text.bubble.fill"].map { StatusItemController.symbol($0) }

    init(state: AppState, correction: CorrectionController, openMainWindow: @escaping () -> Void) {
        self.state = state
        self.correction = correction
        self.openMainWindow = openMainWindow
        super.init()

        // A chosen machine needs no local model, so show the icon as soon as either is ready.
        // @Published emits before the property changes, so use the emitted values, not state's.
        Publishers.CombineLatest3(state.$loadedModelID, state.$engine, state.$machines)
            .map { loadedModelID, engine, machines in AppState.isReady(loadedModelID: loadedModelID, engine: engine, machines: machines) }
            .removeDuplicates()
            .sink { [weak self] isReady in self?.setVisible(isReady) }
            .store(in: &subscriptions)

        correction.$phase
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] isShowing in self?.showCorrection(isShowing) }
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

        if !state.machines.isEmpty {
            menu.addItem(engineItem("This Mac", engine: .onDevice))
            state.machines.forEach { menu.addItem(engineItem($0.name, engine: .machine($0.id))) }
        }
        menu.addItem(rephraseMenu())
        let correct = item("Correct Selected Text", action: #selector(correctSelection), key: "r")
        correct.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(correct)
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

    private func engineItem(_ title: String, engine: Engine) -> NSMenuItem {
        let item = item(title, action: #selector(selectEngine(_:)), isOn: state.engine == engine)
        item.representedObject = engine.rawValue
        return item
    }

    private func rephraseMenu() -> NSMenuItem {
        let submenu = NSMenu()
        for level in RephraseLevel.allCases {
            let item = item(level.title, action: #selector(selectRephraseLevel(_:)), isOn: state.rephraseLevel == level)
            item.representedObject = level.rawValue
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: "Rephrasing: \(state.rephraseLevel.title)", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    // The popover drops from the menu bar icon, like a system extra. It closes when you click elsewhere.
    private func makeCorrectionPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let controller = NSHostingController(rootView: CorrectionView(controller: correction))
        // The popover follows the view's size as it changes and stays attached to the icon.
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        return popover
    }

    private func showCorrection(_ isShowing: Bool) {
        guard isShowing else {
            if correctionPopover.isShown { correctionPopover.performClose(nil) }
            return
        }
        guard let button = statusItem?.button else {
            NSSound.beep()
            correction.dismiss()
            return
        }
        correctionPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        if correction.phase != nil { correction.dismiss() }
    }

    // Run once the menu has closed, so the copy goes to the app that owns the selection.
    @objc private func correctSelection() {
        DispatchQueue.main.async { [correction] in correction.start() }
    }

    @objc private func selectRephraseLevel(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let level = RephraseLevel(rawValue: rawValue) else { return }
        state.rephraseLevel = level
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        state.engine = Engine(rawValue: rawValue)
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
