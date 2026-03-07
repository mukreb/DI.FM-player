import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()
    private var channelsWindow: NSWindow?

    private override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "DI.FM Player")
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

        // Playback status
        if player.isLoading {
            let item = NSMenuItem(title: "Laden…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if player.isPlaying, let channel = player.currentChannel {
            let item = NSMenuItem(title: "Stop: \(channel.name)", action: #selector(stopPlayback), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
            menu.addItem(item)
        }

        if let error = player.errorMessage {
            let item = NSMenuItem(title: "Fout: \(error)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        // Favorites
        if settings.hasListenKey {
            menu.addItem(.separator())
            let favorites = store.channels.filter { settings.favoriteIDs.contains($0.id) }
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
                let label = store.channels.isEmpty ? "Geen favorieten — beheer kanalen" : "Geen favorieten"
                let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        if settings.hasListenKey {
            let item = NSMenuItem(title: "Kanalen beheren…", action: #selector(openChannels), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        let settingsItem = NSMenuItem(title: "Instellingen…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Afsluiten", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func openChannels() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = channelsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView:
            ChannelPickerView()
                .environmentObject(SettingsManager.shared)
                .environmentObject(ChannelStore.shared)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Kanalen"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 360, height: 500))
        window.center()
        channelsWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}
