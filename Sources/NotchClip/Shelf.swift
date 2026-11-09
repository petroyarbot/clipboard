import Foundation

// Полка: временное хранилище файлов, папок и текста, которые перетащили в островок.
// Каждый элемент копируется в `<dataDir>/Shelf/<uuid>/<имя>`; список лежит в `<dataDir>/shelf.json`.

struct ShelfItem: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case file, folder, text }

    let id: UUID
    /// Имя на диске и в списке. Уникально внутри полки (см. `ShelfNaming.unique`).
    let name: String
    let kind: Kind
    let addedAt: Date
    let byteCount: Int64
}

enum ShelfNaming {
    /// Убирает символы, которые нельзя использовать в имени файла, и пустоту по краям.
    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .map { $0 == "/" || $0 == ":" || $0.isNewline ? " " : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Файл" : cleaned
    }

    /// "a.txt" -> "a 2.txt", если "a.txt" занято; у папок и файлов без расширения суффикс ставится в конец.
    static func unique(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            if !taken.contains(candidate) { return candidate }
            index += 1
        }
    }

    /// Имя для текстовой заметки: первая непустая строка, не длиннее `maxLength` символов.
    static func textName(from text: String, maxLength: Int = 40) -> String {
        let firstLine = text
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard !firstLine.isEmpty else { return "Заметка" }
        let sanitized = sanitize(firstLine)
        guard sanitized.count > maxLength else { return sanitized }
        return String(sanitized.prefix(maxLength - 1)) + "…"
    }
}

enum ShelfRetention {
    static let defaultDays = 7
    static let key = "shelfRetentionDays"

    /// Срок хранения из настроек; некорректные значения дают 7 дней, допустимо от 1 до 365.
    static func days(defaults: UserDefaults) -> Int {
        guard let stored = defaults.object(forKey: key) as? Int else { return defaultDays }
        return min(max(stored, 1), 365)
    }

    /// Элементы, добавленные раньше `now - days`.
    static func expired(_ items: [ShelfItem], now: Date, days: Int) -> [ShelfItem] {
        let cutoff = now.addingTimeInterval(-Double(max(days, 1)) * 86_400)
        return items.filter { $0.addedAt < cutoff }
    }
}

/// Что копировать или записать на диск при добавлении.
enum ShelfPayload: Sendable {
    case copy(URL)
    case write(Data)
}

@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    /// Текст последней ошибки для показа пользователю; nil, если всё в порядке.
    @Published var lastError: String?

    let dataDir: URL
    var retentionDays: Int
    private let now: () -> Date

    var shelfDir: URL { dataDir.appendingPathComponent("Shelf", isDirectory: true) }
    private var indexURL: URL { dataDir.appendingPathComponent("shelf.json") }

    init(dataDir: URL, retentionDays: Int = ShelfRetention.defaultDays, now: @escaping () -> Date = { Date() }) {
        self.dataDir = dataDir
        self.retentionDays = retentionDays
        self.now = now
        items = loadIndex()
        purgeExpired()
    }

    /// Путь к содержимому элемента (для Quick Look, перетаскивания и Finder).
    func url(for item: ShelfItem) -> URL {
        shelfDir
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
            .appendingPathComponent(item.name, isDirectory: item.kind == .folder)
    }

    /// Копирует файлы и папки на полку. Порядок: новые сверху.
    @discardableResult
    func add(urls: [URL]) async -> [ShelfItem] {
        var taken = Set(items.map(\.name))
        var incoming: [IncomingEntry] = []
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let name = ShelfNaming.unique(ShelfNaming.sanitize(url.lastPathComponent), taken: taken)
            taken.insert(name)
            incoming.append(IncomingEntry(id: UUID(), name: name, kind: isFolder ? .folder : .file, payload: .copy(url)))
        }
        return await materialize(incoming)
    }

    /// Файл из памяти, например картинка, которую перетащили из браузера.
    @discardableResult
    func add(data: Data, named name: String) async -> ShelfItem? {
        let taken = Set(items.map(\.name))
        let unique = ShelfNaming.unique(ShelfNaming.sanitize(name), taken: taken)
        return await materialize([IncomingEntry(id: UUID(), name: unique, kind: .file, payload: .write(data))]).first
    }

    /// Текстовая заметка: сохраняется как .txt, имя берётся из первой строки.
    @discardableResult
    func addText(_ text: String) async -> ShelfItem? {
        let taken = Set(items.map(\.name))
        let name = ShelfNaming.unique(ShelfNaming.textName(from: text) + ".txt", taken: taken)
        let entry = IncomingEntry(id: UUID(), name: name, kind: .text, payload: .write(Data(text.utf8)))
        return await materialize([entry]).first
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let fileManager = FileManager.default
        for id in ids {
            let folder = shelfDir.appendingPathComponent(id.uuidString, isDirectory: true)
            try? fileManager.removeItem(at: folder)
        }
        items.removeAll { ids.contains($0.id) }
        saveIndex()
    }

    /// "Очистить полку".
    func clear() {
        remove(ids: Set(items.map(\.id)))
    }

    /// Удаляет элементы старше срока хранения. Вызывается при запуске и периодически.
    func purgeExpired() {
        let expired = ShelfRetention.expired(items, now: now(), days: retentionDays)
        remove(ids: Set(expired.map(\.id)))
    }

    // MARK: Внутреннее

    private struct IncomingEntry: Sendable {
        let id: UUID
        let name: String
        let kind: ShelfItem.Kind
        let payload: ShelfPayload
    }

    private func materialize(_ incoming: [IncomingEntry]) async -> [ShelfItem] {
        guard !incoming.isEmpty else { return [] }
        let directory = shelfDir
        let stamp = now()
        let (added, failures) = await Task.detached(priority: .userInitiated) {
            ShelfStore.write(incoming, into: directory, addedAt: stamp)
        }.value
        if !added.isEmpty {
            items.insert(contentsOf: added.reversed(), at: 0)
            saveIndex()
        }
        if !failures.isEmpty {
            lastError = "Не удалось добавить: \(failures.joined(separator: ", "))"
        }
        return added
    }

    /// Копирование и запись выполняются вне главного потока. Ошибка одного элемента не ломает остальные.
    nonisolated private static func write(_ incoming: [IncomingEntry], into shelfDir: URL, addedAt: Date) -> (added: [ShelfItem], failures: [String]) {
        let fileManager = FileManager.default
        var added: [ShelfItem] = []
        var failures: [String] = []
        for entry in incoming {
            let folder = shelfDir.appendingPathComponent(entry.id.uuidString, isDirectory: true)
            let target = folder.appendingPathComponent(entry.name, isDirectory: entry.kind == .folder)
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                switch entry.payload {
                case .copy(let source): try fileManager.copyItem(at: source, to: target)
                case .write(let data): try data.write(to: target)
                }
                added.append(ShelfItem(id: entry.id, name: entry.name, kind: entry.kind, addedAt: addedAt, byteCount: byteCount(of: target)))
            } catch {
                try? fileManager.removeItem(at: folder)
                failures.append(entry.name)
            }
        }
        return (added, failures)
    }

    nonisolated private static func byteCount(of url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isFolder) else { return 0 }
        guard isFolder.boolValue else {
            return Int64((try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0)
        }
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private func loadIndex() -> [ShelfItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: indexURL),
              let stored = try? decoder.decode([ShelfItem].self, from: data) else { return [] }
        // Элемент без файла на диске (например, удалён вручную) в список не попадает, и его папка чистится.
        return stored.filter { item in
            if FileManager.default.fileExists(atPath: url(for: item).path) { return true }
            let folder = shelfDir.appendingPathComponent(item.id.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            return false
        }
    }

    private func saveIndex() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            try encoder.encode(items).write(to: indexURL, options: .atomic)
        } catch {
            lastError = "Не удалось сохранить полку."
        }
    }
}
