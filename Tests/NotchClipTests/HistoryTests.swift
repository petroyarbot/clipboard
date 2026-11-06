import XCTest
@testable import NotchClip

final class HistoryTests: XCTestCase {
    func testDeduplicatesAndMovesToFront() {
        var history = History()
        let first = Clip(kind: .text, data: Data("one".utf8))
        history.add(first)
        history.add(Clip(kind: .text, data: Data("two".utf8)))
        history.add(first)
        XCTAssertEqual(history.clips.map(\.data), [Data("one".utf8), Data("two".utf8)])
    }
    func testLimitAndEmptyItems() {
        var history = History(); history.limit = 1
        history.add(Clip(kind: .text, data: Data()))
        XCTAssertTrue(history.clips.isEmpty)
        history.add(Clip(kind: .text, data: Data("a".utf8)))
        history.add(Clip(kind: .image, data: Data([1, 2])))
        XCTAssertEqual(history.clips.count, 1)
        XCTAssertEqual(history.clips.first?.kind, .image)
    }
    func testPersistenceAndRemoval() throws {
        var history = History()
        let clip = Clip(kind: .image, data: Data([1, 2, 3]))
        history.add(clip)
        var restored = try JSONDecoder().decode(History.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(restored.clips, [clip])
        restored.remove(clip.id)
        XCTAssertTrue(restored.clips.isEmpty)
    }
}

extension HistoryTests {
    func testLegacyHistoryAndPinnedRetention() throws {
        let json = """
        {"clips":[{"id":"9D42AFC8-6B55-4B7A-8743-A5A1EE593777","kind":"text","data":"b2xk","createdAt":0}],"limit":1}
        """
        var history = try JSONDecoder().decode(History.self, from: Data(json.utf8))
        let id = try XCTUnwrap(history.clips.first?.id)
        XCTAssertFalse(history.clips[0].isPinned)
        history.togglePin(id)
        history.add(Clip(kind: .text, data: Data("one".utf8)))
        history.add(Clip(kind: .image, data: Data([1])))
        XCTAssertEqual(history.clips.count, 2)
        XCTAssertEqual(history.ordered.first?.id, id)
        history.clear()
        XCTAssertEqual(history.clips.map(\.id), [id])
    }
    func testEditingAndDeduplicationPreservePin() {
        var history = History()
        let item = Clip(kind: .text, data: Data("a".utf8))
        history.add(item); history.togglePin(item.id)
        history.edit(item.id, text: "updated")
        history.add(Clip(kind: .text, data: Data("updated".utf8)))
        XCTAssertEqual(history.clips.count, 1)
        XCTAssertEqual(history.clips[0].id, item.id)
        XCTAssertTrue(history.clips[0].isPinned)
        XCTAssertEqual(String(data: history.clips[0].data, encoding: .utf8), "updated")
    }
}
