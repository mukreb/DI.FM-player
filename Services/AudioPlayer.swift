import AppKit
import AVFoundation
import MediaToolbox
import Foundation
import MediaPlayer

/// What the menu bar shows while a stream is playing.
enum StreamHealth {
    case ok
    /// Waiting for data: our connection (or DI.FM's server) isn't delivering fast enough.
    case buffering
    /// Data arrives and plays, but the audio itself is silent: the problem is at DI.FM's source.
    case silent
}

@MainActor
class AudioPlayer: ObservableObject {
    static let shared = AudioPlayer()

    @Published var currentChannel: Channel?
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var streamHealth: StreamHealth = .ok
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
    /// Measures the decoded audio level, to tell a silent source from a stalled connection.
    private var levelMeter: AudioLevelMeter?
    private var healthTask: Task<Void, Never>?
    /// Bumped on every user-initiated stop/play so stale async work can detect it was superseded.
    private var generation = 0

    private static let stallTimeout: UInt64 = 15 // seconds of buffering before reconnecting
    private static let maxReconnectAttempts = 10 // ~4.5 min of retries with backoff
    private static let startBufferSeconds = 2.0 // short cushion before first playback
    private static let startBufferTimeout: TimeInterval = 3 // never delay the start longer than this
    private static let rebufferStepSeconds = 4.0 // rebuffer target grows 4, 8, 12, … per stall
    private static let maxRebufferSeconds = 20.0
    private static let bufferWaitTimeout: TimeInterval = 25 // max wait for the buffer target
    private static let silenceLevel: Float = 0.001 // peak below -60 dBFS counts as silence
    private static let silenceDuration: TimeInterval = 2 // silence this long while playing → .silent

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
        stopHealthMonitor()
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
        attachLevelMeter(to: item, asset: asset)
        startHealthMonitor()

        // Host and path only: the query carries the listen key.
        NSLog("DI.FM Player: stream started (%@) %@%@", channel.name, url.host ?? "", url.path)
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
        levelMeter = nil
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
        logStatus(status, item: item)
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

    /// Every play/wait/pause transition goes to the log, so a dropout AVPlayer handles
    /// on its own (without a stalled notification) still leaves a trace.
    private func logStatus(_ status: AVPlayer.TimeControlStatus, item: AVPlayerItem) {
        let name: String
        switch status {
        case .playing: name = "playing"
        case .paused: name = "paused"
        case .waitingToPlayAtSpecifiedRate:
            name = "waiting (\(player?.reasonForWaitingToPlay?.rawValue ?? "unknown"))"
        @unknown default: name = "unknown"
        }
        NSLog("DI.FM Player: status %@, %.1fs buffered", name, Self.bufferedAhead(of: item))
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
        guard bufferTrackingWorks else {
            NSLog("DI.FM Player: playback stalled, no buffer info; leaving recovery to AVPlayer")
            return
        }
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

    // MARK: - Stream health (menu bar indicator)

    /// Taps the decoded audio once the asset's track is known. If the tap can't be set up,
    /// the meter never reports audio and silence detection simply stays off.
    private func attachLevelMeter(to item: AVPlayerItem, asset: AVURLAsset) {
        Task { [weak self] in
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let self, self.player?.currentItem === item,
                  let made = AudioLevelMeter.make() else { return }
            let (meter, tap) = made
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
            self.levelMeter = meter
        }
    }

    /// Polls twice a second while playing (across reconnects) and publishes streamHealth.
    private func startHealthMonitor() {
        guard healthTask == nil else { return }
        healthTask = Task { [weak self] in
            var silentSince: Date?
            while !Task.isCancelled {
                guard let self, self.isPlaying else { return }
                let peak = self.levelMeter?.takePeak()
                let health: StreamHealth
                if self.reconnectTask != nil || self.bufferGateTask != nil
                    || self.player?.timeControlStatus != .playing {
                    health = .buffering
                    silentSince = nil
                } else if let peak, peak < Self.silenceLevel {
                    let since = silentSince ?? Date()
                    silentSince = since
                    health = Date().timeIntervalSince(since) >= Self.silenceDuration ? .silent : .ok
                } else {
                    // Audio is playing, or the meter isn't (yet) reporting.
                    health = .ok
                    silentSince = nil
                }
                if health != self.streamHealth {
                    NSLog("DI.FM Player: health %@", "\(health)")
                    self.streamHealth = health
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func stopHealthMonitor() {
        healthTask?.cancel()
        healthTask = nil
        streamHealth = .ok
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
                        self.stopHealthMonitor()
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

// MARK: - Audio level meter

/// Wraps an MTAudioProcessingTap that records the peak sample level of the decoded audio.
/// The tap's process callback runs on an AVFoundation audio thread and only writes `peak`;
/// the main actor reads and resets it. A racy Float read/write is harmless for a meter.
private final class AudioLevelMeter {
    fileprivate var peak: Float = 0
    /// True once the tap has processed audio in a float format we can measure.
    fileprivate var isMeasuring = false
    fileprivate var isFloat = false

    private init() {}

    /// The tap holds the meter (released in finalize); the meter does not hold the tap.
    static func make() -> (AudioLevelMeter, MTAudioProcessingTap)? {
        let meter = AudioLevelMeter()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            // The tap keeps the meter alive; finalize releases it.
            clientInfo: Unmanaged.passRetained(meter).toOpaque(),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<AudioLevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let meter = Unmanaged<AudioLevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                let asbd = format.pointee
                meter.isFloat = asbd.mFormatID == kAudioFormatLinearPCM
                    && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
                    && asbd.mBitsPerChannel == 32
            },
            unprepare: nil,
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                         flagsOut, nil, numberFramesOut) == noErr else { return }
                let meter = Unmanaged<AudioLevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                guard meter.isFloat else { return }
                var peak: Float = 0
                for buffer in UnsafeMutableAudioBufferListPointer(bufferListInOut) {
                    guard let data = buffer.mData else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    for i in 0..<count { peak = max(peak, abs(samples[i])) }
                }
                meter.peak = max(meter.peak, peak)
                meter.isMeasuring = true
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged.passUnretained(meter).release() // balance passRetained: finalize won't run
            return nil
        }
        return (meter, tap)
    }

    /// Peak level since the last call, or nil while the tap hasn't measured any audio.
    func takePeak() -> Float? {
        guard isMeasuring else { return nil }
        let value = peak
        peak = 0
        return value
    }
}
