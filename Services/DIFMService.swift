import Foundation

class DIFMService {
    static let shared = DIFMService()
    private init() {}

    private let channelsURL = URL(string: "https://listen.di.fm/premium_high.json")!

    func fetchChannels() async throws -> [Channel] {
        let (data, _) = try await URLSession.shared.data(from: channelsURL)
        let channels = try JSONDecoder().decode([Channel].self, from: data)
        return channels.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func fetchStreamURL(for channel: Channel, listenKey: String) async throws -> URL {
        // Force HTTPS — DI.FM playlist URLs may come back as http://
        let playlistString = channel.playlist.replacingOccurrences(of: "http://", with: "https://")
        let urlString = "\(playlistString)?listen_key=\(listenKey)"
        guard let url = URL(string: urlString) else { throw DIFMError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let content = String(data: data, encoding: .utf8) else { throw DIFMError.invalidPLS }
        return try parsePLS(content)
    }

    private func parsePLS(_ content: String) throws -> URL {
        for line in content.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            guard lower.hasPrefix("file"), lower.contains("=") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            // Behoud de URL exact zoals de PLS hem aanlevert (http://prem2.di.fm:80/...).
            // prem-servers weigeren HTTPS op :443 (ECONNREFUSED). HTTP:80 werkt alleen
            // zonder App Sandbox — sandbox blokkeert anders de AVFoundation IPC.
            let urlString = String(parts[parts.count - 1]).trimmingCharacters(in: .whitespaces)
            if parts.count == 2, let url = URL(string: urlString) {
                return url
            }
        }
        throw DIFMError.noStreamFound
    }
}

enum DIFMError: LocalizedError {
    case invalidURL, invalidPLS, noStreamFound

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Ongeldige URL"
        case .invalidPLS: return "Kan afspeellijst niet lezen"
        case .noStreamFound: return "Geen stream gevonden in afspeellijst"
        }
    }
}
