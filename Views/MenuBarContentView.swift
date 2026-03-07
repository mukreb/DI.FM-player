import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var channelStore: ChannelStore
    @Environment(\.openWindow) private var openWindow

    var favoriteChannels: [Channel] {
        channelStore.channels.filter { settings.favoriteIDs.contains($0.id) }
    }

    var body: some View {
        // Playback status
        if player.isLoading {
            Button(action: {}) {
                Label("Loading…", systemImage: "ellipsis")
            }
            .disabled(true)
        } else if player.isPlaying, let channel = player.currentChannel {
            Button { player.stop() } label: {
                Label("Stop: \(channel.name)", systemImage: "stop.circle.fill")
            }
        }

        if let error = player.errorMessage {
            Text("Error: \(error)")
                .foregroundColor(.red)
        }

        // Favorites
        if settings.hasListenKey {
            if !favoriteChannels.isEmpty {
                Divider()
                ForEach(favoriteChannels) { channel in
                    Button {
                        Task {
                            await player.toggle(channel: channel, listenKey: settings.listenKey)
                        }
                    } label: {
                        let isCurrent = player.currentChannel?.id == channel.id && player.isPlaying
                        Label(channel.name,
                              systemImage: isCurrent ? "speaker.wave.2.fill" : "music.note")
                    }
                }
            } else if channelStore.channels.isEmpty {
                Divider()
                Text("No favorites — manage channels")
                    .foregroundColor(.secondary)
            } else {
                Divider()
                Text("No favorites")
                    .foregroundColor(.secondary)
            }
        }

        Divider()

        if settings.hasListenKey {
            Button("Manage Channels…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "channels")
            }
        }

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
