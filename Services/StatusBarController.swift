import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?

    private override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "DI.FM Player")
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Open settings immediately if no listen key is configured
        if !SettingsManager.shared.hasListenKey {
            Task { self.openSettings() }
        }

        // Trigger early initialization of ChannelStore
        _ = ChannelStore.shared

        // Update icon when playback state changes
        AudioPlayer.shared.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                self?.updateIcon(playing: playing)
            }
            .store(in: &cancellables)
    }

    private func updateIcon(playing: Bool) {
        statusItem.button?.image = NSImage(
            systemSymbolName: playing ? "waveform.circle.fill" : "waveform",
            accessibilityDescription: "DI.FM Player"
        )
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            let menu = buildMenu()
            NSMenu.popUpContextMenu(menu, with: event, for: sender)
        } else {
            togglePlayback()
        }
    }

    private func togglePlayback() {
        let player = AudioPlayer.shared
        if player.isPlaying {
            player.stop()
        } else if let channel = player.currentChannel {
            Task {
                await player.play(channel: channel, listenKey: SettingsManager.shared.listenKey)
            }
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let player = AudioPlayer.shared
        let settings = SettingsManager.shared
        let store = ChannelStore.shared
        let favorites = store.channels.filter { settings.favoriteIDs.contains($0.id) }

        // Playback status
        if player.isLoading {
            let item = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if player.isPlaying, let channel = player.currentChannel {
            let item = NSMenuItem(title: "Stop: \(channel.name)", action: #selector(stopPlayback), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
            menu.addItem(item)
        }

        // Next / Previous favorite
        if settings.hasListenKey && !favorites.isEmpty {
            let prevItem = NSMenuItem(title: "Previous", action: #selector(previousFavorite), keyEquivalent: "")
            prevItem.target = self
            prevItem.image = NSImage(systemSymbolName: "backward.fill", accessibilityDescription: nil)
            menu.addItem(prevItem)

            let nextItem = NSMenuItem(title: "Next", action: #selector(nextFavorite), keyEquivalent: "")
            nextItem.target = self
            nextItem.image = NSImage(systemSymbolName: "forward.fill", accessibilityDescription: nil)
            menu.addItem(nextItem)
        }

        if let error = player.errorMessage {
            let item = NSMenuItem(title: "Error: \(error)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        // Favorites
        if settings.hasListenKey {
            menu.addItem(.separator())
            if !favorites.isEmpty {
                for channel in favorites {
                    let isCurrent = player.currentChannel?.id == channel.id && player.isPlaying
                    let item = NSMenuItem(title: channel.name, action: #selector(channelSelected(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = channel
                    item.image = NSImage(
                        systemSymbolName: isCurrent ? "speaker.wave.2.fill" : "music.note",
                        accessibilityDescription: nil
                    )
                    menu.addItem(item)
                }
            } else {
                let label = store.channels.isEmpty ? "No favorites — open Settings" : "No favorites"
                let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let volumeItem = NSMenuItem()
        volumeItem.view = VolumeSliderView(volume: AudioPlayer.shared.volume)
        menu.addItem(volumeItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    @objc private func channelSelected(_ sender: NSMenuItem) {
        guard let channel = sender.representedObject as? Channel else { return }
        Task {
            await AudioPlayer.shared.toggle(channel: channel, listenKey: SettingsManager.shared.listenKey)
        }
    }

    @objc private func stopPlayback() {
        AudioPlayer.shared.stop()
    }

    @objc private func nextFavorite() {
        let favorites = ChannelStore.shared.channels.filter { SettingsManager.shared.favoriteIDs.contains($0.id) }
        guard !favorites.isEmpty else { return }
        let currentID = AudioPlayer.shared.currentChannel?.id
        let next: Channel
        if let currentID, let idx = favorites.firstIndex(where: { $0.id == currentID }) {
            next = favorites[(idx + 1) % favorites.count]
        } else {
            next = favorites[0]
        }
        Task { await AudioPlayer.shared.play(channel: next, listenKey: SettingsManager.shared.listenKey) }
    }

    @objc private func previousFavorite() {
        let favorites = ChannelStore.shared.channels.filter { SettingsManager.shared.favoriteIDs.contains($0.id) }
        guard !favorites.isEmpty else { return }
        let currentID = AudioPlayer.shared.currentChannel?.id
        let prev: Channel
        if let currentID, let idx = favorites.firstIndex(where: { $0.id == currentID }) {
            prev = favorites[(idx - 1 + favorites.count) % favorites.count]
        } else {
            prev = favorites[0]
        }
        Task { await AudioPlayer.shared.play(channel: prev, listenKey: SettingsManager.shared.listenKey) }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView:
            SettingsView()
                .environmentObject(SettingsManager.shared)
                .environmentObject(ChannelStore.shared)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 540))
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

}

private class VolumeSliderView: NSView {
    private let slider = NSSlider()
    private let iconView = NSImageView()

    init(volume: Float) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 36))

        iconView.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Volume")
        iconView.contentTintColor = .secondaryLabelColor

        slider.minValue = 0
        slider.maxValue = 1
        slider.floatValue = volume
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(slider)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            slider.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let newVolume = sender.floatValue
        Task { @MainActor in
            AudioPlayer.shared.volume = newVolume
            SettingsManager.shared.volume = newVolume
        }
    }
}
