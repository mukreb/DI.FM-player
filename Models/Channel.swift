import Foundation

struct Channel: Codable, Identifiable, Hashable {
    let id: Int
    let key: String
    let name: String
    let playlist: String
}
