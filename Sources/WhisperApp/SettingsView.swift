import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                HeaderRow(state: state)
            }

            Section("General") {
                Toggle("Load model when the app starts", isOn: $state.loadModelAtStart)
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
            }

            Section {
                ForEach(WhisperModel.all) { ModelRow(model: $0, state: state) }
            } header: {
                Text("Model")
            } footer: {
                ModelFooter(state: state)
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
                    Text(transcript)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
                Text("Wisper").font(.title2.weight(.semibold))
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
                Text("macOS needs you to allow Wisper in Login Items.")
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
