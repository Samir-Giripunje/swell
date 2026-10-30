import AppKit
import AVFoundation
import Speech

/// Marks the keystrokes Swell types, so its own hotkey monitor doesn't mistake them for the user's.
enum SyntheticKeys {
    static let marker: Int64 = 0x5357_454C // "SWEL"

    static func isOurs(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker
    }
}

/// Live dictation: words are typed into the frontmost app as you speak, and only the last word or two
/// is ever revised, like macOS and Gboard dictation. Apple's SpeechTranscriber (macOS 26) does the
/// recognition: in testing it revised only the last word, where DictationTranscriber rewrote up to
/// 26 words back and WhisperKit couldn't keep up past ~5 s of speech.
@MainActor
final class LiveDictationSession {
    /// Why live dictation can't run here, or nil when it can.
    static var unavailableReason: String? {
        guard #available(macOS 26, *) else { return "Live dictation needs macOS 26." }
        return SpeechTranscriber.isAvailable ? nil : "This Mac can't run Apple's live speech recognition."
    }

    private let typer: LiveTyper
    private let finishTranscribing: () async throws -> String
    /// Takes each chunk of 16 kHz mono samples, on the audio thread.
    nonisolated let appendSamples: @Sendable ([Float]) -> Void

    var isInterrupted: Bool { typer.isInterrupted }

    private init(typer: LiveTyper, appendSamples: @escaping @Sendable ([Float]) -> Void, finish: @escaping () async throws -> String) {
        self.typer = typer
        self.appendSamples = appendSamples
        finishTranscribing = finish
    }

    /// Downloads Apple's speech model for the language if needed, then starts listening.
    static func start(language: DictationLanguage) async throws -> LiveDictationSession {
        guard #available(macOS 26, *) else { throw LiveDictationError.unavailable(unavailableReason ?? "") }
        let typer = LiveTyper()
        let transcriber = try await LiveTranscriber.start(language: language) { text in typer.show(text) }
        return LiveDictationSession(
            typer: typer,
            appendSamples: { samples in transcriber.append(samples) },
            finish: { try await transcriber.finish() }
        )
    }

    static func prepare(language: DictationLanguage) async throws {
        guard #available(macOS 26, *) else { throw LiveDictationError.unavailable(unavailableReason ?? "") }
        try await LiveTranscriber.installModel(for: language)
    }

    /// Finalizes the last words, types them, and returns the whole text.
    func finish() async -> String {
        let text = (try? await finishTranscribing()) ?? typer.typed
        typer.show(text)
        typer.stop()
        return text
    }

    /// Stops typing and keeps what's already in the app.
    func cancel() {
        typer.stop()
        Task { _ = try? await finishTranscribing() }
    }
}

enum LiveDictationError: LocalizedError {
    case unavailable(String)
    case unsupportedLanguage

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .unsupportedLanguage: "Apple's live speech recognition doesn't support this language."
        }
    }
}

@available(macOS 26, *)
private final class LiveTranscriber: @unchecked Sendable {
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let analyzer: SpeechAnalyzer
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let format: AVAudioFormat
    private let results: Task<String, Error>

    private init(input: AsyncStream<AnalyzerInput>.Continuation, analyzer: SpeechAnalyzer, converter: AVAudioConverter,
                 sourceFormat: AVAudioFormat, format: AVAudioFormat, results: Task<String, Error>) {
        self.input = input
        self.analyzer = analyzer
        self.converter = converter
        self.sourceFormat = sourceFormat
        self.format = format
        self.results = results
    }

    static func module(for language: DictationLanguage) async throws -> SpeechTranscriber {
        // Auto-detect isn't possible while streaming; Swell's other language is English.
        let wanted = language == .english ? Locale(identifier: "en-US") : Locale.current
        let fallback = Locale(identifier: "en-US")
        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
        if locale == nil { locale = await SpeechTranscriber.supportedLocale(equivalentTo: fallback) }
        guard let locale else { throw LiveDictationError.unsupportedLanguage }
        // fastResults and volatileResults give words about once a second, with only the last word revised.
        return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    static func installModel(for language: DictationLanguage) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module(for: language)]) {
            try await request.downloadAndInstall()
        }
    }

    static func start(language: DictationLanguage, onText: @escaping @MainActor (String) -> Void) async throws -> LiveTranscriber {
        let module = try await module(for: language)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)!
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
              let converter = AVAudioConverter(from: sourceFormat, to: format) else { throw LiveDictationError.unsupportedLanguage }
        let analyzer = SpeechAnalyzer(modules: [module])
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        let results = Task<String, Error> {
            var finalized = ""
            for try await result in module.results {
                let text = String(result.text.characters)
                if result.isFinal { finalized += text }
                let shown = (result.isFinal ? finalized : finalized + text).trimmingCharacters(in: .whitespaces)
                await onText(shown)
            }
            return finalized.trimmingCharacters(in: .whitespaces)
        }
        return LiveTranscriber(input: input, analyzer: analyzer, converter: converter, sourceFormat: sourceFormat, format: format, results: results)
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / sourceFormat.sampleRate) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var delivered = false
        converter.convert(to: converted, error: nil) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async throws -> String {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await results.value
    }
}

/// The keystrokes that turn what's typed into the new text: delete back to the first difference, then type the rest.
/// Never deletes more than was typed, so text that was in the app before dictation is safe.
struct LiveEdit: Equatable {
    let deletions: Int
    let insertion: String

    init(deletions: Int, insertion: String) {
        self.deletions = deletions
        self.insertion = insertion
    }

    init(from typed: String, to text: String) {
        let common = zip(typed, text).prefix { $0 == $1 }.count
        deletions = typed.count - common
        insertion = String(text.dropFirst(common))
    }
}

/// Types text into the frontmost app and revises its tail by deleting only characters it typed itself.
/// Clicking or switching apps stops it, so it never edits text the user has moved away from.
@MainActor
private final class LiveTyper {
    private static let chunkLength = 20

    private(set) var typed = ""
    private(set) var isInterrupted = false
    private let target = NSWorkspace.shared.frontmostApplication?.processIdentifier
    private let source = CGEventSource(stateID: .hidSystemState)
    private var appSwitchObserver: NSObjectProtocol?
    private var clickMonitor: Any?

    init() {
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, app?.processIdentifier != self.target else { return }
                self.isInterrupted = true
            }
        }
        // A click can move the cursor, after which backspacing would delete the wrong text.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.isInterrupted = true }
        }
    }

    func show(_ text: String) {
        guard !isInterrupted, text != typed else { return }
        let edit = LiveEdit(from: typed, to: text)
        deleteCharacters(edit.deletions)
        type(edit.insertion)
        typed = text
    }

    func stop() {
        appSwitchObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        appSwitchObserver = nil
        clickMonitor.map(NSEvent.removeMonitor)
        clickMonitor = nil
    }

    // Explicit empty flags: the dictation key is held while this types, and ⌘ must not turn "w" into ⌘W.
    private func type(_ text: String) {
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: Self.chunkLength) {
            var chunk = Array(units[start..<min(start + Self.chunkLength, units.count)])
            post(virtualKey: 0) { $0.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk) }
        }
    }

    private func deleteCharacters(_ count: Int) {
        for _ in 0..<max(count, 0) { post(virtualKey: 51) { _ in } }
    }

    private func post(virtualKey: CGKeyCode, configure: (CGEvent) -> Void) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: isDown) else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticKeys.marker)
            configure(event)
            event.post(tap: .cghidEventTap)
        }
    }
}
