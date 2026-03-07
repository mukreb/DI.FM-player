# DI.FM Player

Native macOS menu bar app voor [DI.FM](https://www.di.fm) premium streaming.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Wat doet het

DI.FM Player zit als klein icoon in je menu bar. Je klikt erop om een stream te starten of te pauzeren — geen Dock-icoon, geen apart venster dat in de weg zit.

- **Linksklik** op het icoon → start/pauzeert de huidige stream
- **Rechtsklik** op het icoon → menu met favorieten, kanaallijst, instellingen
- Herstart automatisch het laatste kanaal bij het opstarten van de app
- Mediaknoppen op toetsenbord en koptelefoon werken (via `MPRemoteCommandCenter`)
- Favorieten worden lokaal opgeslagen

## Vereisten

- macOS 13 Ventura of nieuwer
- Een [DI.FM Premium](https://www.di.fm/premium) abonnement
- Je **Listen Key** (te vinden op di.fm → Settings → Hardware Player)

## Installatie

1. Clone of download de repository
2. Open `DI.FM Player.xcodeproj` in Xcode
3. Bouw en start met `⌘R`
4. Klik rechts op het menu bar icoon → **Instellingen…**
5. Voer je Listen Key in en sla op
6. Klik rechts → **Kanalen beheren…** om favorieten toe te voegen

## Architectuur

| Bestand | Verantwoordelijkheid |
|---|---|
| `DI_FM_PlayerApp.swift` | App entry point, SwiftUI `Settings` scene |
| `Services/StatusBarController.swift` | `NSStatusItem` — klikgedrag, menu opbouwen, icoon-updates |
| `Services/AudioPlayer.swift` | AVPlayer wrapper, mediaknoppen |
| `Services/DIFMService.swift` | API-aanroepen, PLS-parsing |
| `Services/SettingsManager.swift` | Listen key + favorieten in UserDefaults |
| `Models/Channel.swift` | Codable channel model |
| `Models/ChannelStore.swift` | Kanalen ophalen, auto-play bij start |
| `Views/ChannelPickerView.swift` | Zoeken en favorieten beheren |
| `Views/SettingsView.swift` | Listen key invoeren |

## DI.FM API

- Kanalen: `GET https://listen.di.fm/premium_high.json`
- Stream: `{channel.playlist}?listen_key={key}` → PLS-bestand → `File1=` URL → AVPlayer
