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
    /// Holds playback paused until enough audio is buffered (briefly at start, longer after a stall).
    private var bufferGateTask: Task<Void, Never>?
    /// Stalls since the user pressed play; each one makes the next rebuffer longer.
    private var stallCount = 0
    /// Set once loadedTimeRanges has reported data for this stream, so the rebuffer gate can trust it.
    private var bufferTrackingWorks = false
    /// Keeps App Nap and timer coalescing away from the stream while playing (LSUIElement app, no windows).
    private var playbackActivity: NSObjectProtocol?
    /// Bumped on every user-initiated stop/play so stale async work can detect it was superseded.
    private var generation = 0

    private static let stallTimeout: UInt64 = 15 // seconds of buffering before reconnecting
    private static let maxReconnectAttempts = 10 // ~4.5 min of retries with backoff
    private static let startBufferSeconds = 2.0 // short cushion before first playback
    private static let startBufferTimeout: TimeInterval = 3 // never delay the start longer than this
    private static let rebufferStepSeconds = 4.0 // rebuffer target grows 4, 8, 12, … per stall
    private static let maxRebufferSeconds = 20.0
    private static let bufferWaitTimeout: TimeInterval = 25 // max wait for the buffer target

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
        stallCount = 0
        tearDownPlayer()
        endPlaybackActivity()
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
        // Forward buffer cap; must stay above maxRebufferSeconds.
        item.preferredForwardBufferDuration = 30
        let player = AVPlayer(playerItem: item)
        player.volume = volume
        // automaticallyWaitsToMinimizeStalling = true (default). On its own this is not
        // enough for a progressive live stream: AVPlayer resumes as soon as it thinks it
        // can keep up, often with under a second of audio, so one network hiccup turns
        // into a series of short dropouts. Playback starts after a short cushion; after a
        // stall, handlePlaybackStalled holds it until a real (and growing) cushion is downloaded.
        self.player = player
        bufferTrackingWorks = false
        observe(item: item, player: player)
        playWhenBuffered(item: item, seconds: Self.startBufferSeconds,
                         timeout: Self.startBufferTimeout, isRebuffer: false)
        beginPlaybackActivity()

        currentChannel = channel
        isPlaying = true
        SettingsManager.shared.lastChannelID = channel.id
        updateNowPlayingInfo()
    }

    private func tearDownPlayer() {
        stallTask?.cancel()
        stallTask = nil
        bufferGateTask?.cancel()
        bufferGateTask = nil
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

        // Buffer ran dry: AVPlayer would resume with a tiny buffer and stutter again.
        itemObservers.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification,
                                                object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handlePlaybackStalled(item: item) }
        })

        itemObservers.append(center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification,
                                                object: item, queue: .main) { _ in
            guard let event = item.errorLog()?.events.last else { return }
            NSLog("DI.FM Player: stream error %ld %@", event.errorStatusCode, event.errorComment ?? "")
        })

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
            if Self.bufferedAhead(of: item) > 0 { bufferTrackingWorks = true }
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

    // MARK: - Buffering

    /// Seconds of downloaded audio ahead of the playhead.
    private static func bufferedAhead(of item: AVPlayerItem) -> Double {
        let now = item.currentTime()
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let end = CMTimeRangeGetEnd(range)
            guard CMTimeCompare(end, now) > 0 else { continue }
            let from = CMTimeMaximum(range.start, now)
            return CMTimeGetSeconds(CMTimeSubtract(end, from))
        }
        return 0
    }

    /// Keeps the player paused until `seconds` of audio are buffered, then plays.
    /// On timeout it plays with what it has, or, after a stall with no data at all, reconnects.
    private func playWhenBuffered(item: AVPlayerItem, seconds target: Double,
                                  timeout: TimeInterval, isRebuffer: Bool) {
        bufferGateTask?.cancel()
        bufferGateTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(timeout)
            while !Task.isCancelled {
                guard let self, let player = self.player, player.currentItem === item else { return }
                let ahead = Self.bufferedAhead(of: item)
                if ahead >= target {
                    self.bufferGateTask = nil
                    player.play()
                    return
                }
                if Date() >= deadline {
                    self.bufferGateTask = nil
                    if isRebuffer && ahead < 1 {
                        self.handleStreamInterrupted(item: item, reason: "no data after stall")
                    } else {
                        NSLog("DI.FM Player: buffer target not reached (%.1fs of %.0fs), playing anyway", ahead, target)
                        player.play()
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func handlePlaybackStalled(item: AVPlayerItem) {
        guard isPlaying, let player, player.currentItem === item,
              bufferGateTask == nil, reconnectTask == nil else { return }
        // Without trustworthy buffer info, leave recovery to AVPlayer and the stall watchdog.
        guard bufferTrackingWorks else { return }
        stallCount += 1
        let target = min(Double(stallCount) * Self.rebufferStepSeconds, Self.maxRebufferSeconds)
        NSLog("DI.FM Player: playback stalled (#%ld), rebuffering %.0fs", stallCount, target)
        // Fresh watchdog once we resume; an old one would exit on .paused and block new ones.
        stallTask?.cancel()
        stallTask = nil
        player.pause()
        playWhenBuffered(item: item, seconds: target,
                         timeout: Self.bufferWaitTimeout, isRebuffer: true)
    }

    private func beginPlaybackActivity() {
        guard playbackActivity == nil else { return }
        playbackActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Streaming audio"
        )
    }

    private func endPlaybackActivity() {
        guard let activity = playbackActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        playbackActivity = nil
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
                        self.endPlaybackActivity()
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
