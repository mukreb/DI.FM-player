import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var channelStore: ChannelStore
    @EnvironmentObject var updater: UpdateChecker

    @State private var draftKey = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }

            ChannelPickerView()
                .tabItem { Label("Channels", systemImage: "music.note.list") }
        }
        .frame(width: 420, height: 540)
        .onAppear {
            draftKey = settings.listenKey
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Listen Key")
                    .font(.subheadline).foregroundColor(.secondary)
                SecureField("Your listen key from di.fm/settings", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                Toggle("Auto-play last channel on launch", isOn: $settings.autoPlayOnLaunch)
                Text("Find your listen key at DI.FM → Settings → Hardware Player.")
                    .font(.caption).foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let newKey = draftKey.trimmingCharacters(in: .whitespaces)
                    let keyChanged = newKey != settings.listenKey
                    settings.listenKey = newKey
                    Task { await channelStore.load(forcePlay: keyChanged) }
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Spacer()

            aboutSection
        }
        .padding(20)
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
                Text("DI.FM Player \(version)")
                    .foregroundColor(.secondary)
                Spacer()
                Button("Check for Updates…") { updater.checkForUpdates() }
            }
        }
    }
}
