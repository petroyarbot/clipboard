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
