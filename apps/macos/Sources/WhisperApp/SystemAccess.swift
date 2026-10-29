import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

enum Permissions {
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
