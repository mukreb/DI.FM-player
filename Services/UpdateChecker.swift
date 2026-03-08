import Sparkle

/// Thin wrapper around Sparkle's SPUStandardUpdaterController.
/// Sparkle handles periodic checks, the update UI, download, and installation automatically.
@MainActor
final class UpdateChecker: NSObject, ObservableObject {
    static let shared = UpdateChecker()

    private let controller: SPUStandardUpdaterController

    override private init() {
        // startingUpdater: true — Sparkle starts checking immediately on launch
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// Triggers a manual update check, showing Sparkle's built-in UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// No-op: Sparkle handles periodic checks via SUEnableAutomaticChecks in Info.plist.
    func startPeriodicChecks() {}
}
