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

            Section("Model") {
                ModelRow(state: state)
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
                Text("Whisper").font(.title2.weight(.semibold))
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
                Text("macOS needs you to allow Whisper in Login Items.")
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
    @ObservedObject var state: AppState

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Whisper tiny")
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            Spacer()
            switch state.modelStatus {
            case .loading:
                ProgressView().controlSize(.small)
            case .loaded:
                Button("Unload") { Task { await state.unloadModel() } }
                    .disabled(state.phase != .idle)
            case .unloaded, .failed:
                Button("Load") { Task { await state.loadModel() } }
            }
        }
    }

    private var statusText: String {
        switch state.modelStatus {
        case .unloaded: "Not loaded — it loads the first time you dictate."
        case .loading: "Loading… the first run downloads about 75 MB."
        case .loaded: "Loaded and ready."
        case .failed(let message): "Failed to load: \(message)"
        }
    }

    private var statusColor: Color {
        switch state.modelStatus {
        case .loaded: .green
        case .failed: .red
        default: .secondary
        }
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
