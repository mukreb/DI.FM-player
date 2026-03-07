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

    private var player: AVPlayer?
    private var commandTargets: [Any] = []

    private init() {
        setupRemoteCommandCenter()
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
        errorMessage = nil
        do {
            let url = try await DIFMService.shared.fetchStreamURL(for: channel, listenKey: listenKey)

            // AVURLAsset with User-Agent so the server returns standard HTTP
            // instead of ICY protocol (SHOUTcast), which AVPlayer does not understand.
            let asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "User-Agent": "iTunes/12.0",
                    "Icy-MetaData": "0"
                ]
            ])
            let item = AVPlayerItem(asset: asset)
            player = AVPlayer(playerItem: item)
            player?.play()

            currentChannel = channel
            isPlaying = true
            SettingsManager.shared.lastChannelID = channel.id
            updateNowPlayingInfo()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func stop() {
        player?.pause()
        player = nil
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
}
