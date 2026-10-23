import AppKit
import AVFoundation
import os
import ServiceManagement

enum ModelStatus: Equatable {
    case unloaded
    case downloading(Double)
    case loading
    case loaded
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .loading: true
        default: false
        }
    }
}

enum DictationPhase {
    case idle
    case recording
    case transcribing
}

// Kept apart from AppState so ~47 level updates a second only redraw the popup.
@MainActor
final class AudioLevelMeter: ObservableObject {
    @Published var level: Float = 0
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    private enum Keys {
        static let loadModelAtStart = "loadModelAtStart"
        static let hotkey = "hotkey"
        static let language = "language"
        static let microphoneUID = "microphoneUID"
        static let selectedModel = "selectedModel"
        static let legacyModelFolder = "cachedModelFolder"
    }

    private static let minimumRecordingSeconds = 0.3
    private static let permissionPollInterval: TimeInterval = 2
    private static let log = Logger(subsystem: "com.samirgiripunje.whisper", category: "dictation")

    @Published var loadModelAtStart: Bool {
        didSet { UserDefaults.standard.set(loadModelAtStart, forKey: Keys.loadModelAtStart) }
    }
    @Published var hotkey: Hotkey {
        didSet {
            UserDefaults.standard.set(hotkey.rawValue, forKey: Keys.hotkey)
            hotkeyMonitor.hotkey = hotkey
        }
    }
    @Published var language: DictationLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Keys.language) }
    }
    // Empty means the system default input.
    @Published var microphoneUID: String {
        didSet { UserDefaults.standard.set(microphoneUID, forKey: Keys.microphoneUID) }
    }

    @Published private(set) var launchAtLoginStatus = LoginItem.status
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var modelStatus = ModelStatus.unloaded
    @Published private(set) var selectedModelID: String
    @Published private(set) var loadedModelID: String?
    @Published private(set) var downloadedModelIDs: Set<String> = []
    @Published private(set) var phase = DictationPhase.idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastError: String?
    @Published private(set) var isAccessibilityTrusted = Permissions.isAccessibilityTrusted
    @Published private(set) var microphoneStatus = Permissions.microphoneStatus

    let meter = AudioLevelMeter()
    private(set) var lastRecording: [Float] = []

    private let transcriber = Transcriber()
    let recorder = AudioRecorder()
    private let hotkeyMonitor = HotkeyMonitor()
    private var loadTask: Task<Void, Never>?
    private var permissionTimer: Timer?

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.loadModelAtStart: true])
        loadModelAtStart = defaults.bool(forKey: Keys.loadModelAtStart)
        hotkey = Hotkey(rawValue: defaults.string(forKey: Keys.hotkey) ?? "") ?? .rightCommand
        language = DictationLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .auto
        microphoneUID = defaults.string(forKey: Keys.microphoneUID) ?? AudioDevices.builtInInput()?.uid ?? ""
        selectedModelID = WhisperModel.with(id: defaults.string(forKey: Keys.selectedModel) ?? "").id
        Self.adoptLegacyTinyDownload()
        downloadedModelIDs = Set(WhisperModel.all.filter(ModelStore.isDownloaded).map(\.id))
        configureCallbacks()
    }

    var isLaunchAtLoginEnabled: Bool {
        launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
    }

    var hasAllPermissions: Bool {
        isAccessibilityTrusted && microphoneStatus == .authorized
    }

    func start() {
        hotkeyMonitor.hotkey = hotkey
        hotkeyMonitor.start()
        if !isAccessibilityTrusted, !SelfTest.isRunning { Permissions.promptForAccessibility() }
        if microphoneStatus == .notDetermined { Task { await requestMicrophone() } }
        pollPermissionsUntilGranted()
        if loadModelAtStart { Task { await loadModel() } }
    }

    func refreshSystemStatus() {
        let trusted = Permissions.isAccessibilityTrusted
        if trusted, !isAccessibilityTrusted { hotkeyMonitor.start() }
        isAccessibilityTrusted = trusted
        microphoneStatus = Permissions.microphoneStatus
        launchAtLoginStatus = LoginItem.status
        if hasAllPermissions {
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else {
            pollPermissionsUntilGranted()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLoginStatus = LoginItem.status
    }

    func selectModel(_ model: WhisperModel, remember: Bool = true) {
        selectedModelID = model.id
        if remember { UserDefaults.standard.set(model.id, forKey: Keys.selectedModel) }
        Task { await loadModel() }
    }

    func loadModel() async {
        while let loadTask { await loadTask.value }
        let model = WhisperModel.with(id: selectedModelID)
        guard loadedModelID != model.id else { return }
        // The task clears loadTask itself, so anyone waiting on it sees nil the moment it finishes.
        let task = Task { @MainActor in
            defer { loadTask = nil }
            do {
                try await prepare(model)
                loadedModelID = model.id
                modelStatus = .loaded
                Self.log.notice("Model loaded: \(model.id, privacy: .public)")
            } catch {
                modelStatus = .failed(error.localizedDescription)
                Self.log.error("Model \(model.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        loadTask = task
        await task.value
        if loadedModelID != selectedModelID, modelStatus == .loaded { await loadModel() }
    }

    func unloadModel() async {
        guard phase == .idle, loadTask == nil else { return }
        await transcriber.unload()
        loadedModelID = nil
        modelStatus = .unloaded
    }

    func deleteModel(_ model: WhisperModel) {
        guard model.id != selectedModelID, model.id != loadedModelID else { return }
        do {
            try ModelStore.delete(model)
            downloadedModelIDs.remove(model.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func prepare(_ model: WhisperModel) async throws {
        if !ModelStore.isDownloaded(model) {
            modelStatus = .downloading(0)
            try await ModelStore.download(model) { fraction in
                Task { @MainActor in
                    if case .downloading = AppState.shared.modelStatus { AppState.shared.modelStatus = .downloading(fraction) }
                }
            }
            downloadedModelIDs.insert(model.id)
        }
        modelStatus = .loading
        try await transcriber.load(from: ModelStore.folder(for: model))
    }

    // Builds before model switching stored the tiny model's folder here; mark it as complete.
    private static func adoptLegacyTinyDownload() {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: Keys.legacyModelFolder) else { return }
        if path == ModelStore.folder(for: .tiny).path, FileManager.default.fileExists(atPath: path) {
            ModelStore.markComplete(.tiny)
        }
        defaults.removeObject(forKey: Keys.legacyModelFolder)
    }

    func requestMicrophone() async {
        _ = await Permissions.requestMicrophone()
        refreshSystemStatus()
    }

    private func configureCallbacks() {
        hotkeyMonitor.onPress = { [weak self] in self?.beginDictation() }
        hotkeyMonitor.onRelease = { [weak self] in self?.finishDictation() }
        hotkeyMonitor.onCancel = { [weak self] cause in self?.cancelDictation(cause: cause) }
        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.meter.level = level }
        }
    }

    func beginDictation() {
        guard phase == .idle else { return }
        guard microphoneStatus == .authorized else {
            Task { await requestMicrophone() }
            return
        }
        if loadedModelID == nil { Task { await loadModel() } }
        do {
            let device = AudioDevices.inputs().first { $0.uid == microphoneUID }
            try recorder.start(device: device?.id)
            lastError = nil
            phase = .recording
            Self.log.notice("Recording started: \(device?.name ?? "system default", privacy: .public), \(self.recorder.inputFormat?.description ?? "unknown", privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            Self.log.error("Recording failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func finishDictation() {
        guard phase == .recording else { return }
        let samples = stopRecording()
        lastRecording = samples
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        let peak = samples.lazy.map(abs).max() ?? 0
        Self.log.notice("Recording stopped after \(seconds, format: .fixed(precision: 2))s, peak amplitude \(peak, format: .fixed(precision: 3))")
        guard seconds >= Self.minimumRecordingSeconds else {
            phase = .idle
            return
        }
        phase = .transcribing
        Task { await transcribeAndPaste(samples) }
    }

    private func cancelDictation(cause: String) {
        guard phase == .recording else { return }
        _ = stopRecording()
        phase = .idle
        Self.log.notice("Recording cancelled by another key: \(cause, privacy: .public)")
    }

    private func stopRecording() -> [Float] {
        let samples = recorder.stop()
        meter.level = 0
        return samples
    }

    private func transcribeAndPaste(_ samples: [Float]) async {
        defer { phase = .idle }
        if loadedModelID == nil { await loadModel() }
        guard loadedModelID != nil else {
            lastError = "The Whisper model isn't loaded."
            return
        }
        do {
            let start = Date()
            let text = try await transcriber.transcribe(samples, language: language)
            Self.log.notice("Transcribed \(text.count) chars in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
            guard !text.isEmpty else { return }
            lastTranscript = text
            if Permissions.isAccessibilityTrusted {
                TextPaster.paste(text)
            } else {
                TextPaster.copy(text)
                lastError = "Turn on Accessibility for Wisper so it can paste. Your text is on the clipboard — press ⌘V."
                Self.log.error("Accessibility not granted; copied transcript to clipboard instead of pasting")
            }
        } catch {
            lastError = error.localizedDescription
            Self.log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func pollPermissionsUntilGranted() {
        guard permissionTimer == nil, !hasAllPermissions else { return }
        let timer = Timer(timeInterval: Self.permissionPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemStatus() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }
}
