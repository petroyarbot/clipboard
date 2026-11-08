import Foundation

struct Clip: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, image, file }
    var id = UUID()
    var kind: Kind
    var data: Data
    var createdAt = Date()
    var isPinned = false
    var linkURL: URL? {
        guard kind == .text, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    init(id: UUID = UUID(), kind: Kind, data: Data, createdAt: Date = Date(), isPinned: Bool = false) {
        self.id = id; self.kind = kind; self.data = data; self.createdAt = createdAt; self.isPinned = isPinned
    }
    enum CodingKeys: String, CodingKey { case id, kind, data, createdAt, isPinned }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(Kind.self, forKey: .kind)
        data = try values.decode(Data.self, forKey: .data)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

struct History: Codable {
    private(set) var clips: [Clip] = []
    var limit = 100
    var ordered: [Clip] { clips.filter(\.isPinned) + clips.filter { !$0.isPinned } }

    /// Returns true only when a new clip was inserted; false for empty data and for a duplicate that was moved to the top.
    @discardableResult mutating func add(_ clip: Clip) -> Bool {
        guard !clip.data.isEmpty else { return false }
        if let existing = clips.first(where: { $0.kind == clip.kind && $0.data == clip.data }) {
            clips.removeAll { $0.id == existing.id }
            var item = existing
            item.createdAt = Date()
            clips.insert(item, at: 0)
            trim()
            return false
        }
        clips.insert(clip, at: 0)
        trim()
        return true
    }
    mutating func togglePin(_ id: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].isPinned.toggle()
        trim()
    }
    mutating func edit(_ id: UUID, text: String) {
        guard let index = clips.firstIndex(where: { $0.id == id && $0.kind == .text }), !text.isEmpty else { return }
        clips[index].data = Data(text.utf8)
    }
    mutating func remove(_ id: UUID) { clips.removeAll { $0.id == id } }
    mutating func clear() { clips.removeAll { !$0.isPinned } }
    mutating func clearAll() { clips.removeAll() }
    private mutating func trim() {
        var unpinned = 0
        clips.removeAll { item in
            guard !item.isPinned else { return false }
            unpinned += 1
            return unpinned > max(0, limit)
        }
    }
}
