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

    private var retryTask: Task<Void, Never>?
    private var retryAttempts = 0

    func load(forcePlay: Bool = false) async {
        guard !isLoading else { return }
        retryTask?.cancel()
        retryTask = nil
        isLoading = true
        errorMessage = nil
        do {
            channels = try await DIFMService.shared.fetchChannels()
            retryAttempts = 0
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            // E.g. app launched before the network was up: keep trying in the background.
            if channels.isEmpty { scheduleRetry(forcePlay: forcePlay) }
            return
        }
        isLoading = false

        let settings = SettingsManager.shared
        guard settings.hasListenKey else { return }
        // Don't interrupt a stream that's already playing unless explicitly asked to.
        guard forcePlay || !AudioPlayer.shared.isPlaying else { return }

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

    private func scheduleRetry(forcePlay: Bool) {
        // Backoff: 5, 10, 20, 40, 60, 60, … seconds
        let delay = min(UInt64(5) << UInt64(min(retryAttempts, 4)), 60)
        retryAttempts += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            await self.load(forcePlay: forcePlay)
        }
    }
}
