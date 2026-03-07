# DI.FM Player

Native macOS menu bar app for [DI.FM](https://www.di.fm) premium streaming.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## What it does

DI.FM Player sits as a small icon in your menu bar. Click it to start or pause a stream — no Dock icon, no separate window getting in the way.

- **Left-click** the icon → start/pause the current stream
- **Right-click** the icon → menu with favorites, channel list, settings
- Automatically restarts the last channel on app launch
- Media keys on keyboard and headphones work (via `MPRemoteCommandCenter`)
- Favorites are stored locally

## Requirements

- macOS 13 Ventura or later
- A [DI.FM Premium](https://www.di.fm/premium) subscription
- Your **Listen Key** (found at di.fm → Settings → Hardware Player)

## Installation

1. Clone or download the repository
2. Open `DI.FM Player.xcodeproj` in Xcode
3. Build and run with `⌘R`
4. Right-click the menu bar icon → **Settings…**
5. Enter your Listen Key and save
6. Right-click → **Manage Channels…** to add favorites

## Architecture

| File | Responsibility |
|---|---|
| `DI_FM_PlayerApp.swift` | App entry point, SwiftUI `Settings` scene |
| `Services/StatusBarController.swift` | `NSStatusItem` — click behavior, menu building, icon updates |
| `Services/AudioPlayer.swift` | AVPlayer wrapper, media keys |
| `Services/DIFMService.swift` | API calls, PLS parsing |
| `Services/SettingsManager.swift` | Listen key + favorites in UserDefaults |
| `Models/Channel.swift` | Codable channel model |
| `Models/ChannelStore.swift` | Fetch channels, auto-play on start |
| `Views/ChannelPickerView.swift` | Search and manage favorites |
| `Views/SettingsView.swift` | Enter listen key |

## DI.FM API

- Channels: `GET https://listen.di.fm/premium_high.json`
- Stream: `{channel.playlist}?listen_key={key}` → PLS file → `File1=` URL → AVPlayer

## Releases

Releases are built automatically via GitHub Actions when a version tag is pushed:

```bash
git tag v1.0.0
git push origin v1.0.0
```

Download the zip from [Releases](../../releases), unzip, and double-click `DI.FM Player.app`.

> **Note:** The app is unsigned. macOS will block it on first launch. Right-click → Open to bypass GateKeeper, or run:
> ```bash
> xattr -cr "/Applications/DI.FM Player.app"
> ```
