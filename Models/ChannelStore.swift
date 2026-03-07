import Foundation

@MainActor
class ChannelStore: ObservableObject {
    static let shared = ChannelStore()

    @Published var channels: [Channel] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private init() {
        // Laad kanalen direct bij app-start als de listen key al is opgeslagen
        if SettingsManager.shared.hasListenKey {
            Task { await load() }
        }
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            channels = try await DIFMService.shared.fetchChannels()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false

        // Auto-play het laatste kanaal bij opstarten
        let settings = SettingsManager.shared
        if settings.hasListenKey,
           let lastID = settings.lastChannelID,
           let channel = channels.first(where: { $0.id == lastID }) {
            await AudioPlayer.shared.play(channel: channel, listenKey: settings.listenKey)
        }
    }
}
