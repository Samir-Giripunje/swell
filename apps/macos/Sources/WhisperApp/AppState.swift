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
        static let engine = "engine"
        static let rephraseLevel = "rephraseLevel"
        static let liveDictation = "liveDictation"
        static let legacyModelFolder = "cachedModelFolder"
    }

    private static let minimumRecordingSeconds = 0.3
    private static let permissionPollInterval: TimeInterval = 2
    // Long enough for a machine on the tailnet, short enough that falling back feels instant.
    private static let reachabilityTimeout: TimeInterval = 1.5
    // While Settings is open, so a machine that wakes up or goes away shows it without pressing ↻.
    private static let machineRefreshInterval: TimeInterval = 5
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

    @Published var engine: Engine {
        didSet {
            UserDefaults.standard.set(engine.rawValue, forKey: Keys.engine)
            // Show the machine's real status right away, not whatever it was when last checked.
            if case .machine(let id) = engine, engine != oldValue { Task { await checkMachine(id) } }
        }
    }
    /// Applied by the machine that transcribes, or by Apple's on-device model when this Mac does.
    @Published var rephraseLevel: RephraseLevel {
        didSet { UserDefaults.standard.set(rephraseLevel.rawValue, forKey: Keys.rephraseLevel) }
    }
    /// Types words into the app as you speak, revising only the last word or two. Uses Apple's live speech
    /// recognition on this Mac, so machines and rephrasing are skipped; ⌃⌥R polishes afterwards.
    @Published var liveDictation: Bool {
        didSet {
            UserDefaults.standard.set(liveDictation, forKey: Keys.liveDictation)
            if liveDictation { prepareLiveDictation() }
        }
    }
    @Published private(set) var liveDictationStatus: String?
    @Published private(set) var machines = MachineStore.load()
    @Published private(set) var machineStatus: [UUID: MachineStatus] = [:]
    /// Set while a pairing link waits for the user to confirm it in Settings.
    @Published var pendingPairing: PairingLink?
    /// The machine transcribing the current dictation, shown in the on-screen pill.
    @Published private(set) var transcribingMachineName: String?

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
    private var isStartingRecording = false
    private var endOnceStarted: (() -> Void)?
    private var recordingStartedAt = Date.distantPast
    private var reachability: (machine: Machine, client: HostClient, probe: Task<MachineStatus, Error>)?
    private var liveSession: Task<LiveDictationSession, Error>?
    private var machineRefresh: Timer?
    private var wantsMachineRefresh = false

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.loadModelAtStart: true])
        loadModelAtStart = defaults.bool(forKey: Keys.loadModelAtStart)
        hotkey = Hotkey(rawValue: defaults.string(forKey: Keys.hotkey) ?? "") ?? .rightCommand
        language = DictationLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .auto
        microphoneUID = defaults.string(forKey: Keys.microphoneUID) ?? AudioDevices.builtInInput()?.uid ?? ""
        selectedModelID = WhisperModel.with(id: defaults.string(forKey: Keys.selectedModel) ?? "").id
        engine = Engine(rawValue: defaults.string(forKey: Keys.engine) ?? "")
        rephraseLevel = RephraseLevel(rawValue: defaults.string(forKey: Keys.rephraseLevel) ?? "") ?? .medium
        liveDictation = defaults.bool(forKey: Keys.liveDictation) && LiveDictationSession.unavailableReason == nil
        Self.adoptLegacyTinyDownload()
        downloadedModelIDs = Set(WhisperModel.all.filter(ModelStore.isDownloaded).map(\.id))
        if case .machine(let id) = engine, !machines.contains(where: { $0.id == id }) { engine = .onDevice }
        configureCallbacks()
    }

    var selectedMachine: Machine? {
        guard case .machine(let id) = engine else { return nil }
        return machines.first { $0.id == id }
    }

    /// Ready to dictate: a remote machine is chosen, or the on-device model is loaded.
    var isReady: Bool { Self.isReady(loadedModelID: loadedModelID, engine: engine, machines: machines) }

    nonisolated static func isReady(loadedModelID: String?, engine: Engine, machines: [Machine]) -> Bool {
        guard loadedModelID == nil, case .machine(let id) = engine else { return loadedModelID != nil }
        return machines.contains { $0.id == id }
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
        machines.forEach { machine in Task { await checkMachine(machine.id) } }
    }

    // MARK: Machines

    /// Pairing the same address again replaces its name and token, so a fresh link fixes a rotated token.
    func addMachine(_ link: PairingLink) throws {
        let id = machines.first { $0.url == link.url }?.id ?? UUID()
        var updated = machines.filter { $0.id != id }
        updated.append(Machine(id: id, name: link.name, url: link.url, token: link.token))
        try MachineStore.save(updated)
        machines = updated
        pendingPairing = nil
        if engine == .machine(id) {
            Task { await checkMachine(id) }
        } else {
            engine = .machine(id)
        }
        if wantsMachineRefresh { startRefreshingMachines() }
    }

    func removeMachine(_ id: UUID) {
        let updated = machines.filter { $0.id != id }
        do {
            try MachineStore.save(updated)
        } catch {
            lastError = "Couldn't remove the machine: \(error.localizedDescription)"
            return
        }
        if engine == .machine(id) { engine = .onDevice }
        machines = updated
        machineStatus[id] = nil
    }

    /// `showsProgress` false refreshes in the background, so the row doesn't flash "Connecting…" every few seconds.
    func checkMachine(_ id: UUID, showsProgress: Bool = true) async {
        guard let machine = machines.first(where: { $0.id == id }) else { return }
        let client = HostClient(url: machine.url, token: machine.token)
        if showsProgress { machineStatus[id] = .checking }
        do {
            machineStatus[id] = try await Self.measureHealth(client, timeout: Self.reachabilityTimeout * 2)
        } catch {
            machineStatus[id] = .offline(error.localizedDescription)
        }
    }

    func startRefreshingMachines() {
        wantsMachineRefresh = true
        guard machineRefresh == nil, !machines.isEmpty else { return }
        refreshMachines()
        let timer = Timer(timeInterval: Self.machineRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMachines() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        machineRefresh = timer
    }

    func stopRefreshingMachines() {
        wantsMachineRefresh = false
        machineRefresh?.invalidate()
        machineRefresh = nil
    }

    private func refreshMachines() {
        for machine in machines {
            Task { await checkMachine(machine.id, showsProgress: machineStatus[machine.id] == nil) }
        }
    }

    private static func measureHealth(_ client: HostClient, timeout: TimeInterval) async throws -> MachineStatus {
        let start = Date()
        let health = try await client.health(timeout: timeout)
        return .online(health, milliseconds: Int(Date().timeIntervalSince(start) * 1000))
    }

    // Starts while the user is still speaking, so by the time they let go we know whether to fall back.
    private func probeSelectedMachine() {
        reachability?.probe.cancel()
        reachability = nil
        guard let machine = selectedMachine else { return }
        let client = HostClient(url: machine.url, token: machine.token)
        reachability = (machine, client, Task { try await Self.measureHealth(client, timeout: Self.reachabilityTimeout) })
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
        guard phase == .idle, !isStartingRecording else { return }
        guard microphoneStatus == .authorized else {
            Task { await requestMicrophone() }
            return
        }
        if liveDictation {
            let language = language
            liveSession = Task { try await LiveDictationSession.start(language: language) }
        } else {
            probeSelectedMachine()
            if loadedModelID == nil, selectedMachine == nil { Task { await loadModel() } }
        }
        isStartingRecording = true
        endOnceStarted = nil
        Task { await startRecording() }
    }

    private func startRecording() async {
        do {
            let (device, format) = try await recorder.start(microphoneUID: microphoneUID)
            isStartingRecording = false
            lastError = nil
            recordingStartedAt = Date()
            phase = .recording
            streamToLiveSession()
            Self.log.notice("Recording started: \(device, privacy: .public), \(format.description, privacy: .public)")
            endOnceStarted?()
        } catch {
            isStartingRecording = false
            cancelLiveSession()
            lastError = error.localizedDescription
            Self.log.error("Recording failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func finishDictation() {
        if isStartingRecording {
            endOnceStarted = { [weak self] in self?.finishDictation() }
            return
        }
        guard phase == .recording else { return }
        // Judge accidental taps by how long the key was held; the samples include the release tail.
        guard Date().timeIntervalSince(recordingStartedAt) >= Self.minimumRecordingSeconds else {
            _ = stopRecording()
            cancelLiveSession()
            phase = .idle
            return
        }
        phase = .transcribing
        if let liveSession {
            self.liveSession = nil
            Task { await finishLiveDictation(liveSession) }
            return
        }
        Task {
            let samples = await recorder.finish()
            meter.level = 0
            lastRecording = samples
            let seconds = Double(samples.count) / AudioRecorder.sampleRate
            let peak = samples.lazy.map(abs).max() ?? 0
            Self.log.notice("Recording stopped after \(seconds, format: .fixed(precision: 2))s, peak amplitude \(peak, format: .fixed(precision: 3))")
            await transcribeAndPaste(samples)
        }
    }

    private func cancelDictation(cause: String) {
        if isStartingRecording {
            endOnceStarted = { [weak self] in self?.cancelDictation(cause: cause) }
            return
        }
        guard phase == .recording else { return }
        _ = stopRecording()
        cancelLiveSession()
        reachability?.probe.cancel()
        reachability = nil
        phase = .idle
        Self.log.notice("Recording cancelled by another key: \(cause, privacy: .public)")
    }

    private func stopRecording() -> [Float] {
        let samples = recorder.stop()
        meter.level = 0
        return samples
    }

    private func transcribeAndPaste(_ samples: [Float]) async {
        defer {
            phase = .idle
            transcribingMachineName = nil
        }
        do {
            let start = Date()
            let text = try await transcribe(samples)
            Self.log.notice("Transcribed \(text.count) chars in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
            guard !text.isEmpty else { return }
            lastTranscript = text
            if Permissions.isAccessibilityTrusted {
                TextPaster.paste(text)
                let target = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown app"
                Self.log.notice("Pasted \(text.count) chars into \(target, privacy: .public)")
            } else {
                TextPaster.copy(text)
                lastError = "Turn on Accessibility for Swell so it can paste. Your text is on the clipboard — press ⌘V."
                Self.log.error("Accessibility not granted; copied transcript to clipboard instead of pasting")
            }
        } catch {
            lastError = error.localizedDescription
            Self.log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func transcribe(_ samples: [Float]) async throws -> String {
        if let (machine, client, probe) = reachability {
            reachability = nil
            transcribingMachineName = machine.name
            do {
                machineStatus[machine.id] = try await probe.value
                return try await client.transcribe(samples, language: language, rephrase: rephraseLevel, timeout: Self.remoteTimeout(forSamples: samples.count))
            } catch {
                machineStatus[machine.id] = .offline(error.localizedDescription)
                Self.log.error("\(machine.name, privacy: .public) failed, transcribing on this Mac: \(error.localizedDescription, privacy: .public)")
                transcribingMachineName = nil
            }
        }
        if loadedModelID == nil { await loadModel() }
        guard loadedModelID != nil else { throw TranscriptionError.modelNotLoaded }
        let text = try await transcriber.transcribe(samples, language: language)
        // No machine did this one, so rephrase here: Low is a word list, Medium and High use Apple's on-device model.
        guard rephraseLevel != .off, !text.isEmpty else { return text }
        let start = Date()
        let rephrased = await OnDeviceRephraser.cleaned(text, level: rephraseLevel)
        Self.log.notice("Rephrased on this Mac (\(self.rephraseLevel.rawValue, privacy: .public)) in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s, changed: \(rephrased != text)")
        return rephrased
    }

    // Generous: the host transcribes and then cleans up the text with a language model.
    static func remoteTimeout(forSamples count: Int) -> TimeInterval {
        8 + Double(count) / AudioRecorder.sampleRate / 4
    }

    // MARK: Live dictation

    private func prepareLiveDictation() {
        if let reason = LiveDictationSession.unavailableReason {
            liveDictationStatus = reason
            liveDictation = false
            return
        }
        liveDictationStatus = "Getting Apple's speech model ready…"
        let language = language
        Task {
            do {
                try await LiveDictationSession.prepare(language: language)
                liveDictationStatus = nil
            } catch {
                liveDictationStatus = error.localizedDescription
            }
        }
    }

    private func cancelLiveSession() {
        guard let liveSession else { return }
        self.liveSession = nil
        Task { try? await liveSession.value.cancel() }
    }

    /// Feeds the recording to live dictation once it's listening, starting with what was already said.
    private func streamToLiveSession() {
        guard let liveSession else { return }
        Task {
            do {
                let session = try await liveSession.value
                recorder.stream(to: session.appendSamples)
            } catch {
                lastError = "Live dictation couldn't start: \(error.localizedDescription)"
                Self.log.error("Live dictation failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func finishLiveDictation(_ liveSession: Task<LiveDictationSession, Error>) async {
        defer { phase = .idle }
        _ = await recorder.finish()
        meter.level = 0
        guard let session = try? await liveSession.value else { return }
        let start = Date()
        let text = await session.finish()
        Self.log.notice("Live dictation finished \(text.count) chars, \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s after release")
        guard !text.isEmpty else { return }
        lastTranscript = text
        if session.isInterrupted {
            TextPaster.copy(text)
            lastError = "Live typing stopped when you clicked or switched apps. The full text is on the clipboard."
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

enum TranscriptionError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? { "The Whisper model isn't loaded." }
}
