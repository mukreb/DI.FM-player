import AppKit
import AVFoundation
import Foundation
import MediaPlayer

@MainActor
class AudioPlayer: ObservableObject {
    static let shared = AudioPlayer()

    @Published var currentChannel: Channel?
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var volume: Float = 1.0 {
        didSet { player?.volume = volume }
    }

    private var player: AVPlayer?
    private var commandTargets: [Any] = []

    // Stream health monitoring / auto-reconnect
    private var itemObservers: [NSObjectProtocol] = []
    private var kvoObservers: [NSKeyValueObservation] = []
    private var stallTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    /// Bumped on every user-initiated stop/play so stale async work can detect it was superseded.
    private var generation = 0

    private static let stallTimeout: UInt64 = 15 // seconds of buffering before reconnecting
    private static let maxReconnectAttempts = 10 // ~4.5 min of retries with backoff

    private init() {
        volume = SettingsManager.shared.volume
        setupRemoteCommandCenter()
        observeSystemWake()
    }

    // MARK: - Media Keys (spacebar / headphone button / Touch Bar)

    private func setupRemoteCommandCenter() {
        let cc = MPRemoteCommandCenter.shared()

        // Disable standard next/previous — radio has no tracks
        cc.nextTrackCommand.isEnabled = false
        cc.previousTrackCommand.isEnabled = false
        cc.skipForwardCommand.isEnabled = false
        cc.skipBackwardCommand.isEnabled = false

        commandTargets.append(
            cc.togglePlayPauseCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                Task { @MainActor in
                    if self.isPlaying {
                        self.stop()
                    } else if let channel = self.currentChannel {
                        await self.play(channel: channel,
                                        listenKey: SettingsManager.shared.listenKey)
                    }
                }
                return .success
            }
        )

        commandTargets.append(
            cc.pauseCommand.addTarget { [weak self] _ in
                self?.stop()
                return .success
            }
        )

        commandTargets.append(
            cc.playCommand.addTarget { [weak self] _ in
                guard let self, !self.isPlaying, let channel = self.currentChannel else {
                    return .commandFailed
                }
                Task { @MainActor in
                    await self.play(channel: channel,
                                    listenKey: SettingsManager.shared.listenKey)
                }
                return .success
            }
        )
    }

    private func updateNowPlayingInfo() {
        if let channel = currentChannel {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: channel.name,
                MPMediaItemPropertyArtist: "DI.FM",
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
            ]
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    // MARK: - Playback

    func play(channel: Channel, listenKey: String) async {
        stop()
        isLoading = true
        do {
            try await startStream(channel: channel, listenKey: listenKey)
        } catch is CancellationError {
            return // superseded by a newer play/stop
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func stop() {
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        tearDownPlayer()
        isLoading = false
        isPlaying = false
        errorMessage = nil
        updateNowPlayingInfo()
    }

    func clearChannel() {
        stop()
        currentChannel = nil
    }

    func toggle(channel: Channel, listenKey: String) async {
        if currentChannel?.id == channel.id && isPlaying {
            stop()
        } else {
            await play(channel: channel, listenKey: listenKey)
        }
    }

    private func startStream(channel: Channel, listenKey: String) async throws {
        let startGeneration = generation
        let url = try await DIFMService.shared.fetchStreamURL(for: channel, listenKey: listenKey)
        guard generation == startGeneration else { throw CancellationError() }

        // AVURLAsset with User-Agent so the server returns standard HTTP
        // instead of ICY protocol (SHOUTcast), which AVPlayer does not understand.
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": [
                "User-Agent": "iTunes/12.0",
                "Icy-MetaData": "0"
            ]
        ])
        let item = AVPlayerItem(asset: asset)
        // Generous forward buffer: absorbs network jitter and brief main-thread blocks.
        item.preferredForwardBufferDuration = 15
        let player = AVPlayer(playerItem: item)
        player.volume = volume
        // automaticallyWaitsToMinimizeStalling = true (default): AVPlayer keeps a
        // decoded audio buffer. Brief main-thread stalls (UI interactions, Sparkle)
        // are absorbed by this buffer instead of causing audible crackling.
        self.player = player
        observe(item: item, player: player)
        player.play()

        currentChannel = channel
        isPlaying = true
        SettingsManager.shared.lastChannelID = channel.id
        updateNowPlayingInfo()
    }

    private func tearDownPlayer() {
        stallTask?.cancel()
        stallTask = nil
        itemObservers.forEach { NotificationCenter.default.removeObserver($0) }
        itemObservers.removeAll()
        kvoObservers.removeAll()
        player?.pause()
        player = nil
    }

    // MARK: - Stream health / auto-reconnect

    private func observe(item: AVPlayerItem, player: AVPlayer) {
        let center = NotificationCenter.default
        // A live stream "ends" when the server drops the connection.
        for name in [AVPlayerItem.didPlayToEndTimeNotification,
                     AVPlayerItem.failedToPlayToEndTimeNotification] {
            itemObservers.append(center.addObserver(forName: name, object: item, queue: .main) { [weak self] note in
                Task { @MainActor in self?.handleStreamInterrupted(item: item, reason: note.name.rawValue) }
            })
        }

        kvoObservers.append(item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.handleStreamInterrupted(item: item, reason: "item failed") }
        })

        kvoObservers.append(player.observe(\.timeControlStatus) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.handleTimeControlStatus(status, item: item) }
        })
    }

    private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus, item: AVPlayerItem) {
        guard player?.currentItem === item else { return }
        switch status {
        case .playing:
            stallTask?.cancel()
            stallTask = nil
            reconnectAttempts = 0
        case .waitingToPlayAtSpecifiedRate:
            // Buffering. If it doesn't recover on its own, the connection is likely dead.
            guard stallTask == nil else { return }
            stallTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.stallTimeout * 1_000_000_000)
                guard !Task.isCancelled, let self,
                      self.player?.currentItem === item,
                      self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
                self.handleStreamInterrupted(item: item, reason: "stalled")
            }
        default:
            break
        }
    }

    private func handleStreamInterrupted(item: AVPlayerItem, reason: String) {
        guard isPlaying, player?.currentItem === item else { return }
        NSLog("DI.FM Player: stream interrupted (\(reason)), reconnecting")
        scheduleReconnect()
    }

    private func scheduleReconnect(immediately: Bool = false) {
        guard reconnectTask == nil, let channel = currentChannel else { return }
        tearDownPlayer()
        isLoading = true
        let startGeneration = generation
        reconnectTask = Task { [weak self] in
            var first = true
            while let self, !Task.isCancelled, self.generation == startGeneration {
                if !(immediately && first) {
                    // Exponential backoff: 1, 2, 4, 8, 16, 30, 30, … seconds
                    let delay = min(UInt64(1) << UInt64(min(self.reconnectAttempts, 5)), 30)
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                }
                first = false
                guard !Task.isCancelled, self.generation == startGeneration else { return }
                self.reconnectAttempts += 1
                do {
                    try await self.startStream(channel: channel,
                                               listenKey: SettingsManager.shared.listenKey)
                    self.isLoading = false
                    self.reconnectTask = nil
                    return
                } catch is CancellationError {
                    return
                } catch {
                    if self.reconnectAttempts >= Self.maxReconnectAttempts {
                        self.reconnectTask = nil
                        self.isLoading = false
                        self.isPlaying = false
                        self.errorMessage = error.localizedDescription
                        self.updateNowPlayingInfo()
                        return
                    }
                }
            }
        }
    }

    private func observeSystemWake() {
        // After sleep the HTTP connection is almost always dead; reconnect right away.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying, self.reconnectTask == nil else { return }
                self.reconnectAttempts = 0
                self.scheduleReconnect(immediately: true)
            }
        }
    }
}
