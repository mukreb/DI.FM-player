import SwiftUI

@main
struct DI_FM_PlayerApp: App {
    init() {
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
