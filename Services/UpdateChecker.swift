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

    /// Start Sparkle's updater. Call this once at app launch, before audio starts.
    func startUpdater() {
        guard !updaterStarted else { return }
        controller.startUpdater()
        updaterStarted = true
    }

    /// Triggers a manual update check, showing Sparkle's built-in UI.
    func checkForUpdates() {
        startUpdater() // no-op if already started
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    private var updaterStarted = false

    /// No-op: kept for compatibility.
    func startPeriodicChecks() {}
}
