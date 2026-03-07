import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var channelStore: ChannelStore
    @Environment(\.dismiss) private var dismiss

    @State private var draftKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("DI.FM Player — Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Listen Key")
                    .font(.subheadline).foregroundColor(.secondary)
                SecureField("Your listen key from di.fm/settings", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                Text("Find your listen key at DI.FM → Settings → Hardware Player.")
                    .font(.caption).foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    settings.listenKey = draftKey.trimmingCharacters(in: .whitespaces)
                    if channelStore.channels.isEmpty {
                        Task { await channelStore.load() }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            draftKey = settings.listenKey
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
