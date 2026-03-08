import SwiftUI

@main
struct DI_FM_PlayerApp: App {
    init() {
        // Start Sparkle BEFORE audio initializes so its brief main-thread
        // work doesn't cause HALC overloads on an active audio stream.
        UpdateChecker.shared.startUpdater()
        _ = StatusBarController.shared
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
