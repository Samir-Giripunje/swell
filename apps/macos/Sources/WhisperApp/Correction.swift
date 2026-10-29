import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// Select text anywhere, press ⌃⌥R, and a machine corrects it; Replace pastes the result over the selection.
@MainActor
final class CorrectionController: ObservableObject {
    enum Phase: Equatable {
        case working
        case done(String)
        case failed(String)
    }

    static let shortcutTitle = "⌃⌥R"
    static let levels: [RephraseLevel] = [.low, .medium, .high]
    /// Past this, the corrected text scrolls in a fixed-height box instead of growing the popover.
    static let scrollingLength = 600
    private static let requestTimeout: TimeInterval = 40
    // Long enough for the popover to close before the paste lands.
    private static let pasteDelay: TimeInterval = 0.1

    /// Nil while no correction is showing. Set only after the selection is read.
    @Published private(set) var phase: Phase? {
        didSet { claimPopoverKeys(phase != nil) }
    }
    @Published private(set) var original = ""
    @Published private(set) var level = RephraseLevel.medium

    private let state: AppState
    private var shortcut: GlobalShortcut?
    private var target: NSRunningApplication?
    private var task: Task<Void, Never>?
    private var popoverKeys: [GlobalShortcut] = []
    private var appSwitchObserver: NSObjectProtocol?

    init(state: AppState) {
        self.state = state
        shortcut = GlobalShortcut(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey) { [weak self] in
            Task { @MainActor in self?.start() }
        }
    }

    // macOS no longer lets an app make itself active, so the app with the selection stays in front while the
    // popover shows. That keeps the selection for Replace; Return and Escape are claimed system-wide meanwhile,
    // so they reach the popover instead of that app, and released as soon as it closes.
    private func claimPopoverKeys(_ claim: Bool) {
        guard claim != !popoverKeys.isEmpty else { return }
        guard claim else {
            popoverKeys = []
            appSwitchObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
            appSwitchObserver = nil
            return
        }
        popoverKeys = [
            GlobalShortcut(keyCode: kVK_Return) { [weak self] in Task { @MainActor in self?.replace() } },
            GlobalShortcut(keyCode: kVK_Escape) { [weak self] in Task { @MainActor in self?.dismiss() } },
        ].compactMap { $0 }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, app?.processIdentifier != self.target?.processIdentifier,
                      app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self.dismiss()
            }
        }
    }

    /// Where the current correction runs, shown while it works.
    @Published private(set) var engineName = "this Mac"
    /// Why a machine wasn't used, when this Mac corrected the text instead.
    @Published private(set) var fallbackNote: String?

    func start() {
        task?.cancel()
        target = NSWorkspace.shared.frontmostApplication
        level = state.rephraseLevel == .off ? .low : state.rephraseLevel
        task = Task {
            guard let text = await Self.selectedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                phase = .failed("Select some text first, then press \(Self.shortcutTitle).")
                return
            }
            original = text
            await correct()
        }
    }

    func choose(_ level: RephraseLevel) {
        guard level != self.level, !original.isEmpty else { return }
        self.level = level
        task?.cancel()
        task = Task { await correct() }
    }

    func replace() {
        guard case .done(let text) = phase else { return }
        let target = target
        dismiss()
        target?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteDelay) {
            if Permissions.isAccessibilityTrusted {
                TextPaster.paste(text)
            } else {
                TextPaster.copy(text)
            }
        }
    }

    func copy() {
        guard case .done(let text) = phase else { return }
        TextPaster.copy(text)
        dismiss()
    }

    func dismiss() {
        task?.cancel()
        task = nil
        phase = nil
        original = ""
    }

    /// The chosen machine first; Apple's on-device model when there is none or it doesn't answer.
    private func correct() async {
        phase = .working
        fallbackNote = nil
        var machineError: String?
        if let machine = state.selectedMachine {
            engineName = machine.name
            do {
                let text = try await HostClient(url: machine.url, token: machine.token).rephrase(original, level: level, timeout: Self.requestTimeout)
                guard !Task.isCancelled else { return }
                phase = .done(text)
                return
            } catch {
                guard !Task.isCancelled else { return }
                machineError = "\(machine.name): \(error.localizedDescription)"
            }
        }
        engineName = "this Mac"
        do {
            let text = try await OnDeviceRephraser.corrected(original, level: level)
            guard !Task.isCancelled else { return }
            fallbackNote = machineError.map { _ in "Corrected on this Mac. \(state.selectedMachine?.name ?? "Your machine") didn't answer." }
            phase = .done(text)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed([machineError, error.localizedDescription].compactMap { $0 }.joined(separator: "\n"))
        }
    }

    /// Accessibility first, since it leaves the clipboard alone; ⌘C for apps that don't expose their selection.
    private static func selectedText() async -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        var selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(),
           AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
           let text = selected as? String, !text.isEmpty {
            return text
        }
        return await TextPaster.copySelection()
    }
}

/// Indices of the words in `rewritten` that aren't in `original`, so the popover can highlight what changed.
enum WordDiff {
    static func changedWords(from original: String, to rewritten: String) -> Set<Int> {
        let before = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let after = rewritten.split(whereSeparator: \.isWhitespace).map(String.init)
        return Set(after.difference(from: before).insertions.compactMap { change in
            if case .insert(let offset, _, _) = change { offset } else { nil }
        })
    }

    static func highlighted(_ rewritten: String, comparedTo original: String) -> AttributedString {
        let changed = changedWords(from: original, to: rewritten)
        var result = AttributedString()
        var cursor = rewritten.startIndex
        for (index, word) in rewritten.split(whereSeparator: \.isWhitespace).enumerated() {
            result += AttributedString(rewritten[cursor..<word.startIndex])
            var piece = AttributedString(word)
            if changed.contains(index) {
                piece.backgroundColor = Color.green.opacity(0.22)
            }
            result += piece
            cursor = word.endIndex
        }
        result += AttributedString(rewritten[cursor...])
        return result
    }
}

struct CorrectionView: View {
    @ObservedObject var controller: CorrectionController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
                Text("Correct text").font(.headline)
                Spacer()
                Picker("Level", selection: Binding(get: { controller.level }, set: { controller.choose($0) })) {
                    ForEach(CorrectionController.levels) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(controller.original.isEmpty)
            }
            content
            buttons
        }
        .padding(16)
        .frame(width: 420)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .working, nil:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Correcting on \(controller.engineName)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        case .done(let text) where text == controller.original:
            Label("Looks good. Nothing to change at this level.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        case .done(let text) where text.count > CorrectionController.scrollingLength:
            ScrollView { corrected(text) }
                .frame(height: 260)
        case .done(let text):
            corrected(text)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        }
    }

    private func corrected(_ text: String) -> some View {
        Text(WordDiff.highlighted(text, comparedTo: controller.original))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buttons: some View {
        HStack {
            Text(controller.fallbackNote ?? "Changes are highlighted.").font(.caption).foregroundStyle(.secondary)
                .opacity(isReplaceable ? 1 : 0)
            Spacer()
            Button("Cancel", role: .cancel) { controller.dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Copy") { controller.copy() }
                .disabled(!isReplaceable)
            Button("Replace") { controller.replace() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isReplaceable)
        }
    }

    private var isReplaceable: Bool {
        if case .done(let text) = controller.phase { return text != controller.original }
        return false
    }
}
