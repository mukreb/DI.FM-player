import AppKit
import Sparkle

/// Thin wrapper around Sparkle's SPUStandardUpdaterController.
/// Sparkle handles periodic checks, the update UI, download, and installation automatically.
@MainActor
final class UpdateChecker: NSObject, ObservableObject {
    static let shared = UpdateChecker()

    private let controller: SPUStandardUpdaterController

    override private init() {
        // startingUpdater: false — we start the updater manually after app launch
        // to avoid blocking the main thread (and causing audio glitches) at startup.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// Call once after the app has fully launched to start Sparkle's background checks.
    func startUpdater() {
        controller.startUpdater()
    }

    /// Triggers a manual update check, showing Sparkle's built-in UI.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// No-op: Sparkle handles periodic checks via SUEnableAutomaticChecks in Info.plist.
    func startPeriodicChecks() {}
}
