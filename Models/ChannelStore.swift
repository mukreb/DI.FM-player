import Foundation

@MainActor
class ChannelStore: ObservableObject {
    static let shared = ChannelStore()

    @Published var channels: [Channel] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private init() {
        // Load channels immediately on app start if the listen key is already saved
        if SettingsManager.shared.hasListenKey {
            Task { await load() }
        }
    }

    func load(forcePlay: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            channels = try await DIFMService.shared.fetchChannels()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false

        let settings = SettingsManager.shared
        guard settings.hasListenKey else { return }

        if settings.autoPlayOnLaunch || forcePlay {
            if let lastID = settings.lastChannelID,
               let channel = channels.first(where: { $0.id == lastID }) {
                await AudioPlayer.shared.play(channel: channel, listenKey: settings.listenKey)
            } else if forcePlay {
                // New key with no history — play first favorite, or first channel
                if let firstFav = channels.first(where: { settings.favoriteIDs.contains($0.id) }) {
                    await AudioPlayer.shared.play(channel: firstFav, listenKey: settings.listenKey)
                } else if let first = channels.first {
                    await AudioPlayer.shared.play(channel: first, listenKey: settings.listenKey)
                }
            }
        }
    }
}
