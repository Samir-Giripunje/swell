import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let state = AppState.shared
    private var overlay: OverlayController?
    private var statusItem: StatusItemController?
    private let settingsTabs = NSTabViewController()
    private lazy var mainWindow = makeMainWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        overlay = OverlayController(state: state)
        statusItem = StatusItemController(state: state) { [weak self] in self?.showMainWindow() }
        let startHidden = LaunchContext.isLoginLaunch && state.hasAllPermissions
        if !startHidden { showMainWindow() }
        state.start()
        SelfTest.runIfRequested(state: state)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        state.refreshSystemStatus()
    }

    // swell://pair links from a host. Ask before adding: anyone can send a link.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let link = urls.lazy.compactMap({ PairingLink($0.absoluteString) }).first else { return }
        state.pendingPairing = link
        showMainWindow()
        settingsTabs.selectedTabViewItemIndex = SettingsTab.engine.rawValue
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // Whisper lives in the Dock and ⌘Tab only while its window is open, like a menu bar utility.
    @objc func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    // Toolbar tabs, like System Settings panes in other Mac apps. One long form was taller than a 13" screen.
    private func makeMainWindow() -> NSWindow {
        settingsTabs.tabStyle = .toolbar
        settingsTabs.addTabViewItem(settingsTab(.general, GeneralSettingsView(state: state)))
        settingsTabs.addTabViewItem(settingsTab(.engine, EngineSettingsView(state: state)))
        let window = NSWindow(contentViewController: settingsTabs)
        window.title = "Swell"
        window.toolbarStyle = .preference
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MainWindow")
        return window
    }

    private func settingsTab(_ tab: SettingsTab, _ view: some View) -> NSTabViewItem {
        let controller = NSHostingController(rootView: view)
        // The tab controller resizes the window to each pane's preferred size as you switch.
        controller.sizingOptions = [.preferredContentSize]
        // The tab controller shows the selected pane's title as the window title.
        controller.title = tab.title
        let item = NSTabViewItem(viewController: controller)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        return item
    }

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Swell", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showMainWindow), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Swell", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Swell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenuItem(appMenu))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(submenuItem(editMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(submenuItem(windowMenu))
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    private func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}

private enum SettingsTab: Int {
    case general
    case engine

    var title: String {
        switch self {
        case .general: "General"
        case .engine: "Engine"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .engine: "cpu"
        }
    }
}
