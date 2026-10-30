import ServiceManagement
import SwiftUI

/// Startup, the hotkey, microphone and language, and permissions.
struct GeneralSettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                HeaderRow(state: state)
            }

            Section("Startup") {
                Toggle("Load the on-device model when Swell starts", isOn: $state.loadModelAtStart)
                Toggle("Launch at login", isOn: Binding(
                    get: { state.isLaunchAtLoginEnabled },
                    set: { state.setLaunchAtLogin($0) }
                ))
                LoginItemNotice(state: state)
            }

            Section("Dictation") {
                Picker("Hold to talk", selection: $state.hotkey) {
                    ForEach(Hotkey.allCases) { Text($0.title).tag($0) }
                }
                MicrophonePicker(state: state)
                Picker("Language", selection: $state.language) {
                    ForEach(DictationLanguage.allCases) { Text($0.title).tag($0) }
                }
                LiveDictationRow(state: state)
            }

            Section("Permissions") {
                PermissionRow(
                    title: "Microphone",
                    detail: "Records your voice while you hold the hotkey.",
                    isGranted: state.microphoneStatus == .authorized,
                    action: {
                        if state.microphoneStatus == .notDetermined {
                            Task { await state.requestMicrophone() }
                        } else {
                            Permissions.openMicrophoneSettings()
                        }
                    }
                )
                PermissionRow(
                    title: "Accessibility",
                    detail: "Detects the hotkey and pastes the text where your cursor is.",
                    isGranted: state.isAccessibilityTrusted,
                    action: {
                        Permissions.promptForAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                )
            }

            if let transcript = state.lastTranscript {
                Section("Last dictation") {
                    // Capped so a long dictation can't stretch the window past the screen.
                    Text(transcript)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .settingsPane()
    }
}

/// Where dictation is transcribed: this Mac, or a paired machine, plus the on-device models.
/// The speech model, rephrasing, and, under Advanced, other computers to transcribe on.
struct EngineSettingsView: View {
    @ObservedObject var state: AppState
    @State private var isAddingMachine = false
    @State private var showsMachines: Bool

    init(state: AppState) {
        self.state = state
        // Most people use one computer; the machines section opens only for those who have paired one.
        _showsMachines = State(initialValue: !state.machines.isEmpty || state.pendingPairing != nil)
    }

    var body: some View {
        Form {
            if state.liveDictation {
                Section {
                    Label(
                        "Rambler is on, so this Mac transcribes as you speak. Rephrasing and your machines are used again when you turn it off in General.",
                        systemImage: "waveform.badge.mic"
                    )
                    .font(.callout)
                }
            }

            Section {
                ForEach(WhisperModel.all) { ModelRow(model: $0, state: state) }
            } header: {
                Text(state.selectedMachine == nil || state.liveDictation ? "Model" : "Model on this Mac")
            } footer: {
                ModelFooter(state: state)
            }

            Section {
                Picker("Rephrasing", selection: $state.rephraseLevel) {
                    ForEach(RephraseLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(state.rephraseLevel.detail).font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Rephrasing")
            } footer: {
                RephrasingFooter(state: state)
            }
            .disabled(state.liveDictation)

            Section {
                DisclosureGroup("Use another computer", isExpanded: $showsMachines) {
                    Text("Transcribe on a more powerful computer running Swell, such as a Linux PC with a GPU, over Tailscale. "
                        + "If it doesn't answer, this Mac transcribes instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !state.machines.isEmpty {
                        EngineRow(
                            title: "This Mac",
                            detail: "\(WhisperModel.with(id: state.selectedModelID).name) model on the Neural Engine. Works offline.",
                            isSelected: state.engine == .onDevice,
                            select: { state.engine = .onDevice }
                        ) {
                            EmptyView()
                        }
                        ForEach(state.machines) { MachineRow(machine: $0, state: state) }
                    }
                    HStack {
                        Spacer()
                        Button("Add Machine…") { isAddingMachine = true }
                    }
                }
            } header: {
                Text("Advanced")
            }
            // Kept as they are, not changed: turning Rambler off brings them straight back.
            .disabled(state.liveDictation)
        }
        .settingsPane()
        .sheet(isPresented: Binding(
            get: { isAddingMachine || state.pendingPairing != nil },
            set: { isPresented in
                guard !isPresented else { return }
                isAddingMachine = false
                state.pendingPairing = nil
            }
        )) {
            AddMachineSheet(state: state, openedLink: state.pendingPairing)
        }
    }
}

private extension View {
    // Each pane takes its natural height, so the window fits the tab instead of the whole app.
    func settingsPane() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 480)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HeaderRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("Swell").font(.title2.weight(.semibold))
                Text("Hold \(state.hotkey.shortTitle), speak, then let go — your words are typed where your cursor is.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let error = state.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MicrophonePicker: View {
    @ObservedObject var state: AppState
    @State private var devices = AudioDevices.inputs()

    var body: some View {
        Picker("Microphone", selection: $state.microphoneUID) {
            Text("System default").tag("")
            ForEach(devices) { device in
                Text(device.isBuiltIn ? "\(device.name) (recommended)" : device.name).tag(device.uid)
            }
        }
        .onAppear { devices = AudioDevices.inputs() }
    }
}

private struct LoginItemNotice: View {
    @ObservedObject var state: AppState

    var body: some View {
        if let error = state.launchAtLoginError {
            Text(error).font(.caption).foregroundStyle(.red)
        } else if state.launchAtLoginStatus == .requiresApproval {
            HStack {
                Text("macOS needs you to allow Swell in Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items") { LoginItem.openSettings() }
                    .controlSize(.small)
            }
        }
    }
}

private struct ModelRow: View {
    let model: WhisperModel
    @ObservedObject var state: AppState

    private var isSelected: Bool { state.selectedModelID == model.id }
    private var isDownloaded: Bool { state.downloadedModelIDs.contains(model.id) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name)
                    Text(model.size).font(.caption).foregroundStyle(.secondary)
                }
                Text(model.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isSelected {
            switch state.modelStatus {
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 80)
                Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
            case .loading:
                ProgressView().controlSize(.small)
                Text("Loading").font(.caption).foregroundStyle(.secondary)
            case .loaded where state.loadedModelID == model.id:
                Label("In use", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
            default:
                Button("Load") { Task { await state.loadModel() } }
            }
        } else {
            if isDownloaded {
                Button("Use") { state.selectModel(model) }
                Button {
                    state.deleteModel(model)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete \(model.name) (\(model.size))")
            } else {
                Button("Download") { state.selectModel(model) }
            }
        }
    }
}

private struct ModelFooter: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack {
            Text(statusText).foregroundStyle(statusColor)
            Spacer()
            if state.loadedModelID != nil {
                Button("Unload from memory") { Task { await state.unloadModel() } }
                    .disabled(state.phase != .idle || state.modelStatus.isBusy)
                    .controlSize(.small)
            }
        }
        .font(.caption)
    }

    private var statusText: String {
        switch state.modelStatus {
        case .unloaded: "Not loaded — it loads the first time you dictate."
        case .downloading: "Downloading… the current model keeps working meanwhile."
        case .loading: "Loading and optimising for the Neural Engine…"
        case .loaded: "Ready. Models run fully on this Mac."
        case .failed(let message): "Couldn't load the model: \(message)"
        }
    }

    private var statusColor: Color {
        if case .failed = state.modelStatus { return .red }
        return .secondary
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isGranted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !isGranted {
                Button("Allow…", action: action)
            }
        }
    }
}

private struct EngineRow<Trailing: View>: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let select: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing
        }
    }
}

private struct MachineRow: View {
    let machine: Machine
    @ObservedObject var state: AppState

    var body: some View {
        EngineRow(
            title: machine.name,
            detail: detail,
            isSelected: state.engine == .machine(machine.id),
            select: { state.engine = .machine(machine.id) }
        ) {
            HStack(spacing: 6) {
                if state.machineStatus[machine.id] == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await state.checkMachine(machine.id) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Test connection")
                }
                Button {
                    state.removeMachine(machine.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove \(machine.name)")
            }
            .buttonStyle(.borderless)
        }
    }

    private var detail: String {
        switch state.machineStatus[machine.id] ?? .unknown {
        case .unknown: machine.url.absoluteString
        case .checking: "Connecting to \(machine.url.absoluteString)…"
        case .online(let health, let milliseconds): "Online · \(health.summary) · \(milliseconds) ms"
        case .offline(let reason): "Offline · \(reason)"
        }
    }
}

private struct AddMachineSheet: View {
    @ObservedObject var state: AppState
    /// A pairing link opened from outside Swell, waiting for confirmation. Nil when pasting one by hand.
    let openedLink: PairingLink?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    private var link: PairingLink? { openedLink ?? PairingLink(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a machine").font(.title3.weight(.semibold))
            Text("On the other computer, open Swell, turn on **Serve other machines**, and click **Copy pairing link**. Paste it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if openedLink == nil {
                SecureField("swell://pair?…", text: $text)
                    .textFieldStyle(.roundedBorder)
            }
            if let link {
                LabeledContent("Machine", value: link.name)
                LabeledContent("Address", value: link.url.absoluteString)
            } else if !text.isEmpty {
                Text("That isn't a Swell pairing link.").font(.caption).foregroundStyle(.red)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(link == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func add() {
        guard let link else { return }
        do {
            try state.addMachine(link)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct RephrasingFooter: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(whoRephrases + " To correct text you typed, select it anywhere and press \(CorrectionController.shortcutTitle).")
            if let reason = OnDeviceRephraser.unavailableReason, state.rephraseLevel != .off, state.rephraseLevel != .low {
                Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var whoRephrases: String {
        guard let machine = state.selectedMachine else { return "Apple Intelligence rephrases on this Mac." }
        return "\(machine.name) rephrases. When it doesn't answer, Apple Intelligence does it on this Mac."
    }
}

private struct LiveDictationRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        Toggle(isOn: $state.liveDictation) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rambler (live dictation)")
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let status = state.liveDictationStatus {
                    Text(status).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .disabled(LiveDictationSession.unavailableReason != nil)
    }

    private var detail: String {
        if let reason = LiveDictationSession.unavailableReason { return reason }
        return "Types as you speak and fixes the last word or two as it hears more. Runs on this Mac with Apple's speech model, "
            + "so your paired machines and rephrasing aren't used while it's on. Select the text and press \(CorrectionController.shortcutTitle) to polish it."
    }
}
