import AppKit
import CoreServices

enum LaunchContext {
    private static let loginWindowSeconds: TimeInterval = 180

    // macOS tags "Open at Login" launches on the open-application Apple event. If that tag is
    // missing, a launch shortly after boot with Launch at login enabled is treated the same way.
    @MainActor
    static var isLoginLaunch: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let taggedAsLoginItem = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        let launchedRightAfterBoot = LoginItem.status == .enabled && ProcessInfo.processInfo.systemUptime < loginWindowSeconds
        return taggedAsLoginItem || launchedRightAfterBoot
    }
}
