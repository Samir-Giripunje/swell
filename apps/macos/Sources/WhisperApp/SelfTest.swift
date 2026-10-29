import AppKit
import AVFoundation
import WhisperKit
import ApplicationServices
import os

// Launch with `--self-test` to dictate a spoken phrase into TextEdit end to end:
// a synthetic right ⌘ press, a spoken phrase (synthesized with `say`) in place of the mic audio,
// release, then read back what landed in TextEdit. A second round checks the real mic is back.
// The test instance quits when it finishes.
@MainActor
enum SelfTest {
    static let launchArgument = "--self-test"
    static var isRunning: Bool { CommandLine.arguments.contains(launchArgument) }

    private static let log = Logger(subsystem: "com.samirgiripunje.whisper", category: "selftest")
    private static let phrase = "Testing the whisper dictation app on my Mac."
    private static let rightCommandKeyCode: CGKeyCode = 54
    private static let rightCommandDeviceBit: UInt64 = 0x10

    static func runIfRequested(state: AppState) {
        guard isRunning else { return }
        Task { await run(state: state) }
    }

    private static func run(state: AppState) async {
        defer { NSApp.terminate(nil) }
        let trusted = Permissions.isAccessibilityTrusted
        report("accessibility=\(trusted) microphone=\(Permissions.microphoneStatus.rawValue)")
        guard let speech = await synthesizeSpeech(phrase) else {
            report("FAIL could not synthesize test speech")
            return
        }
        await state.loadModel()
        report("model=\(state.loadedModelID ?? "none") status=\(state.modelStatus)")
        if let requested = requestedModel() {
            await switchModel(to: requested, state: state)
        }

        guard let textEdit = await openBlankTextEditDocument() else {
            report("FAIL could not open TextEdit")
            return
        }
        try? await Task.sleep(for: .seconds(2))
        report("frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")

        state.recorder.injectedSamples = speech
        await dictateOnce(state: state, trusted: trusted)
        report("round 1 (test phrase) transcript=\(state.lastTranscript ?? "nil") error=\(state.lastError ?? "none")")
        try? await Task.sleep(for: .seconds(1))
        report("textedit=\(focusedText(of: textEdit) ?? "unreadable")")

        await dictateOnce(state: state, trusted: trusted)
        let usedMic = state.lastRecording != speech
        report("round 2 (real mic) usedMic=\(usedMic) samples=\(state.lastRecording.count)")
        report("recording saved to \(saveWAV(state.lastRecording).path)")

        reportWindowCloseBehavior()
        report("DONE")
    }

    private static func requestedModel() -> WhisperModel? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--model"), index + 1 < arguments.count else { return nil }
        return WhisperModel.all.first { $0.id == arguments[index + 1] }
    }

    private static func switchModel(to model: WhisperModel, state: AppState) async {
        let start = Date()
        report("switching to \(model.id), downloaded=\(ModelStore.isDownloaded(model))")
        state.selectModel(model, remember: false)
        var lastReportedTenth = -1
        while state.loadedModelID != model.id {
            if case .failed(let message) = state.modelStatus {
                report("FAIL switching model: \(message)")
                return
            }
            if case .downloading(let fraction) = state.modelStatus, Int(fraction * 10) > lastReportedTenth {
                lastReportedTenth = Int(fraction * 10)
                report("downloading \(lastReportedTenth * 10)%")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        report("switched to \(model.id) in \(Int(Date().timeIntervalSince(start)))s")
    }

    private static func dictateOnce(state: AppState, trusted: Bool) async {
        if trusted { postRightCommand(down: true) } else { state.beginDictation() }
        try? await Task.sleep(for: .milliseconds(1700))
        if trusted { postRightCommand(down: false) } else { state.finishDictation() }
        await waitUntilIdle(state)
    }

    private static func reportWindowCloseBehavior() {
        report("before close: policy=\(policyName) visibleWindows=\(NSApp.windows.filter(\.isVisible).map(\.title))")
        NSApp.windows.first { $0.title == "Swell" }?.performClose(nil)
        report("after close: policy=\(policyName)")
    }

    private static var policyName: String {
        switch NSApp.activationPolicy() {
        case .regular: "regular (Dock + ⌘Tab)"
        case .accessory: "accessory (background, menu bar only)"
        default: "prohibited"
        }
    }

    private static func report(_ message: String) {
        log.notice("SELFTEST \(message, privacy: .public)")
    }

    private static func openBlankTextEditDocument() async -> NSRunningApplication? {
        guard let textEditURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            return nil
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-self-test.txt")
        try? Data().write(to: file)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return try? await NSWorkspace.shared.open([file], withApplicationAt: textEditURL, configuration: configuration)
    }

    private static func postRightCommand(down: Bool) {
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: rightCommandKeyCode, keyDown: down)
        event?.type = .flagsChanged
        event?.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | rightCommandDeviceBit) : []
        event?.post(tap: .cghidEventTap)
    }

    private static func synthesizeSpeech(_ text: String) async -> [Float]? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-self-test-phrase.aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", file.path, text]
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume()
            }
        }
        return try? AudioProcessor.loadAudioAsFloatArray(fromPath: file.path)
    }

    private static func saveWAV(_ samples: [Float]) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-self-test.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: AudioRecorder.sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let file = try? AVAudioFile(forWriting: url, settings: format.settings) else { return url }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try? file.write(from: buffer)
        return url
    }

    private static func waitUntilIdle(_ state: AppState) async {
        for _ in 0..<100 where state.phase != .idle {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func focusedText(of app: NSRunningApplication) -> String? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
