import Foundation

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    private let defaults = UserDefaults.standard

    @Published var listenKey: String {
        didSet { defaults.set(listenKey, forKey: "listenKey") }
    }

    @Published var favoriteIDs: Set<Int> {
        didSet { defaults.set(Array(favoriteIDs), forKey: "favoriteIDs") }
    }

    @Published var volume: Float {
        didSet { defaults.set(volume, forKey: "volume") }
    }

    @Published var autoPlayOnLaunch: Bool {
        didSet { defaults.set(autoPlayOnLaunch, forKey: "autoPlayOnLaunch") }
    }

    var lastChannelID: Int? {
        get { defaults.object(forKey: "lastChannelID") as? Int }
        set {
            if let id = newValue { defaults.set(id, forKey: "lastChannelID") }
            else { defaults.removeObject(forKey: "lastChannelID") }
        }
    }

    var hasListenKey: Bool { !listenKey.trimmingCharacters(in: .whitespaces).isEmpty }

    private init() {
        listenKey = defaults.string(forKey: "listenKey") ?? ""
        favoriteIDs = Set(defaults.array(forKey: "favoriteIDs") as? [Int] ?? [])
        volume = defaults.object(forKey: "volume") as? Float ?? 1.0
        autoPlayOnLaunch = defaults.object(forKey: "autoPlayOnLaunch") as? Bool ?? true
    }

    func toggleFavorite(channelID: Int) {
        if favoriteIDs.contains(channelID) {
            favoriteIDs.remove(channelID)
        } else {
            favoriteIDs.insert(channelID)
        }
    }

}
