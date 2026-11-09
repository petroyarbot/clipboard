import Foundation

// Проверки полки: имена, срок хранения, копирование, текст, удаление, сохранение списка и очистка.

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition {
        print("ok   - \(name)")
    } else {
        print("FAIL - \(name)")
        failures += 1
    }
}

final class FakeClock {
    var now: Date
    init(_ start: Date) { now = start }
    func advance(days: Double) { now = now.addingTimeInterval(days * 86_400) }
}

// MARK: 1. Имена

check(ShelfNaming.unique("a.txt", taken: []) == "a.txt", "naming: free name is kept")
check(ShelfNaming.unique("a.txt", taken: ["a.txt"]) == "a 2.txt", "naming: taken name gets suffix 2")
check(ShelfNaming.unique("a.txt", taken: ["a.txt", "a 2.txt"]) == "a 3.txt", "naming: suffix skips taken numbers")
check(ShelfNaming.unique("README", taken: ["README"]) == "README 2", "naming: no extension suffix goes to the end")
check(ShelfNaming.unique("Photos", taken: ["Photos"]) == "Photos 2", "naming: folder names get suffix too")
check(ShelfNaming.unique("archive.tar.gz", taken: ["archive.tar.gz"]) == "archive.tar 2.gz", "naming: only the last extension is kept")
check(ShelfNaming.sanitize("a/b:c") == "a b c", "naming: slash and colon are replaced")
check(ShelfNaming.sanitize("   ") == "Файл", "naming: blank name falls back")
check(ShelfNaming.textName(from: "  Привет мир \nвторая строка") == "Привет мир", "text name: first non-empty line")
check(ShelfNaming.textName(from: "\n\n  \n") == "Заметка", "text name: empty text falls back")
let longName = ShelfNaming.textName(from: String(repeating: "я", count: 60))
check(longName.count == 40 && longName.hasSuffix("…"), "text name: long line is cut with ellipsis")

// MARK: 2. Срок хранения

let day: TimeInterval = 86_400
let now = Date(timeIntervalSince1970: 2_000_000_000)
func item(daysAgo: Double, name: String = "x") -> ShelfItem {
    ShelfItem(id: UUID(), name: name, kind: .file, addedAt: now.addingTimeInterval(-daysAgo * day), byteCount: 1)
}
let mixed = [item(daysAgo: 8, name: "old"), item(daysAgo: 6, name: "fresh"), item(daysAgo: 7.5, name: "edge")]
check(ShelfRetention.expired(mixed, now: now, days: 7).map(\.name) == ["old", "edge"], "retention: items older than the window expire")
check(ShelfRetention.expired(mixed, now: now, days: 30).isEmpty, "retention: longer window keeps everything")
check(ShelfRetention.expired(mixed, now: now, days: 0).count == 3, "retention: zero days is clamped to one day")

let suiteName = "notchclip-shelf-test-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }
check(ShelfRetention.days(defaults: defaults) == 7, "retention: default is 7 days")
defaults.set(14, forKey: ShelfRetention.key)
check(ShelfRetention.days(defaults: defaults) == 14, "retention: stored value is used")
defaults.set(9999, forKey: ShelfRetention.key)
check(ShelfRetention.days(defaults: defaults) == 365, "retention: value is capped at 365")

// MARK: 3. Хранилище

let fileManager = FileManager.default
let root = fileManager.temporaryDirectory.appendingPathComponent("notchclip-shelf-\(UUID().uuidString)", isDirectory: true)
defer { try? fileManager.removeItem(at: root) }
let source = root.appendingPathComponent("source", isDirectory: true)
try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
let dataDir = root.appendingPathComponent("data", isDirectory: true)
let clock = FakeClock(now)

let fileURL = source.appendingPathComponent("report.pdf")
try Data("pdf-bytes".utf8).write(to: fileURL)
let folderURL = source.appendingPathComponent("Photos", isDirectory: true)
try fileManager.createDirectory(at: folderURL.appendingPathComponent("nested"), withIntermediateDirectories: true)
try Data("0123456789".utf8).write(to: folderURL.appendingPathComponent("nested/a.jpg"))

let store = ShelfStore(dataDir: dataDir, retentionDays: 7, now: { clock.now })
check(store.items.isEmpty, "store: starts empty")

let added = await store.add(urls: [fileURL, folderURL])
check(added.count == 2, "store: adds files and folders")
check(store.items.first?.name == "Photos" && store.items.last?.name == "report.pdf", "store: newest item is first")
let reportItem = store.items.first { $0.name == "report.pdf" }!
let copied = store.url(for: reportItem)
check(copied.path.hasPrefix(dataDir.appendingPathComponent("Shelf").path), "store: copy lives under Shelf dir")
check((try? Data(contentsOf: copied)) == Data("pdf-bytes".utf8), "store: file content is copied")
check(reportItem.byteCount == 9, "store: file byte count recorded")
let photos = store.items.first { $0.name == "Photos" }!
check(fileManager.fileExists(atPath: store.url(for: photos).appendingPathComponent("nested/a.jpg").path), "store: folder copied recursively")
check(photos.kind == .folder && photos.byteCount == 10, "store: folder kind and size")
check(fileURL.path.hasSuffix("report.pdf") && fileManager.fileExists(atPath: fileURL.path), "store: source file is left untouched")

let again = await store.add(urls: [fileURL])
check(again.first?.name == "report 2.pdf", "store: same name on shelf gets unique display name")
check(store.items.count == 3, "store: duplicate is stored as a separate item")

let note = await store.addText("Список покупок\nмолоко")
check(note?.name == "Список покупок.txt" && note?.kind == .text, "store: text note is named from first line")
let noteURL = store.url(for: note!)
check((try? String(contentsOf: noteURL, encoding: .utf8)) == "Список покупок\nмолоко", "store: text note content is saved")

let image = await store.add(data: Data([0x89, 0x50]), named: "Изображение.png")
check(image?.name == "Изображение.png" && image?.byteCount == 2, "store: in-memory data is written as file")

// Persistence: a new store with the same folder reads the list back.
let reloaded = ShelfStore(dataDir: dataDir, retentionDays: 7, now: { clock.now })
check(reloaded.items.map(\.id) == store.items.map(\.id), "store: list survives restart in the same order")
check(fileManager.fileExists(atPath: dataDir.appendingPathComponent("shelf.json").path), "store: shelf.json is written")

// Missing files are dropped on load.
try fileManager.removeItem(at: store.url(for: note!))
let afterManualDelete = ShelfStore(dataDir: dataDir, retentionDays: 7, now: { clock.now })
check(!afterManualDelete.items.contains { $0.id == note!.id }, "store: items whose file vanished are not loaded")

// Removal deletes the folder and updates the list.
let removedID = store.items.first { $0.name == "report.pdf" }!.id
store.remove(ids: [removedID])
check(!store.items.contains { $0.id == removedID }, "store: remove drops the item")
check(!fileManager.fileExists(atPath: dataDir.appendingPathComponent("Shelf/\(removedID.uuidString)").path), "store: remove deletes its folder")

// Retention: items older than the window disappear with their folders.
let oldStore = ShelfStore(dataDir: dataDir, retentionDays: 7, now: { clock.now })
let oldCount = oldStore.items.count
clock.advance(days: 8)
oldStore.purgeExpired()
check(oldStore.items.isEmpty && oldCount > 0, "store: purge removes items older than retention")
check(!fileManager.fileExists(atPath: dataDir.appendingPathComponent("Shelf").appendingPathComponent(photos.id.uuidString).path), "store: purge deletes expired folders")

// Clear empties the shelf.
_ = await oldStore.add(urls: [fileURL])
oldStore.clear()
check(oldStore.items.isEmpty, "store: clear empties the shelf")
check((try? fileManager.contentsOfDirectory(atPath: dataDir.appendingPathComponent("Shelf").path))?.isEmpty ?? true, "store: clear leaves no item folders")

// Missing source is reported, not thrown.
let failed = await oldStore.add(urls: [source.appendingPathComponent("missing.bin")])
check(failed.isEmpty && oldStore.lastError != nil, "store: missing source sets lastError and adds nothing")

print(failures == 0 ? "All Shelf checks passed." : "\(failures) Shelf check(s) failed.")
exit(failures == 0 ? 0 : 1)

