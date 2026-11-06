import Foundation

struct Clip: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, image }
    var id = UUID()
    var kind: Kind
    var data: Data
    var createdAt = Date()
}

struct History: Codable {
    private(set) var clips: [Clip] = []
    var limit = 100

    mutating func add(_ clip: Clip) {
        guard !clip.data.isEmpty else { return }
        clips.removeAll { $0.kind == clip.kind && $0.data == clip.data }
        clips.insert(clip, at: 0)
        clips = Array(clips.prefix(max(0, limit)))
    }
    mutating func remove(_ id: UUID) { clips.removeAll { $0.id == id } }
    mutating func clear() { clips.removeAll() }
}
