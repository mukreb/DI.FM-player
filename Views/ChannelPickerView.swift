import SwiftUI

struct ChannelPickerView: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var channelStore: ChannelStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""

    var filtered: [Channel] {
        guard !searchText.isEmpty else { return channelStore.channels }
        return channelStore.channels.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Manage Channels")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()

            Divider()

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if channelStore.isLoading {
                ProgressView("Loading channels…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = channelStore.errorMessage {
                VStack(spacing: 8) {
                    Text(error).foregroundColor(.red)
                    Button("Retry") {
                        Task { await channelStore.load() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { channel in
                    HStack {
                        Text(channel.name)
                        Spacer()
                        Button {
                            settings.toggleFavorite(channelID: channel.id)
                        } label: {
                            Image(systemName: settings.favoriteIDs.contains(channel.id)
                                  ? "star.fill" : "star")
                            .foregroundColor(settings.favoriteIDs.contains(channel.id)
                                             ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(width: 360, height: 500)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            if channelStore.channels.isEmpty && !channelStore.isLoading {
                Task { await channelStore.load() }
            }
        }
    }
}
