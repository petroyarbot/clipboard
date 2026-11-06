import XCTest
import AppKit
@testable import NotchClip

@MainActor final class ClipboardStoreTests: XCTestCase {
    func testMixedTextAndImageAndReload() throws {
        let board = NSPasteboard(name: .init("notchclip-test-\(UUID())"))
        defer { board.releaseGlobally() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ClipboardStore(pasteboard: board, fileURL: file)
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        let item = NSPasteboardItem()
        item.setString("some text", forType: .string)
        item.setData(try XCTUnwrap(image.tiffRepresentation), forType: .tiff)
        board.clearContents(); board.writeObjects([item]); store.poll()
        XCTAssertEqual(store.history.clips.first?.kind, .text)
        XCTAssertEqual(store.history.clips.first.flatMap { String(data: $0.data, encoding: .utf8) }, "some text")
        let restored = ClipboardStore(pasteboard: board, fileURL: file)
        XCTAssertEqual(restored.history.clips, store.history.clips)
        board.clearContents(); board.writeObjects([image]); store.poll()
        XCTAssertEqual(store.history.clips.first?.kind, .image)
        let savedImage = try XCTUnwrap(store.history.clips.first)
        store.select(savedImage)
        XCTAssertNotNil(NSImage(pasteboard: board))
    }
}
