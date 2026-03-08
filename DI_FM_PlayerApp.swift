import SwiftUI

@main
struct DI_FM_PlayerApp: App {
    init() {
        _ = StatusBarController.shared
        // Start Sparkle's updater after a short delay so it doesn't block
        // the main thread during app startup (which causes audio glitches).
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UpdateChecker.shared.startUpdater()
        }
    }

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(SettingsManager.shared)
                .environmentObject(ChannelStore.shared)
                .environmentObject(UpdateChecker.shared)
        }
    }
}
