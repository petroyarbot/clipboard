import AppKit
import Foundation
@main struct Check {
 @MainActor static func main() throws {
  let board = NSPasteboard(name: .init("notchclip-test-\(UUID())")); defer { board.releaseGlobally() }
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:file) }
  let store = ClipboardStore(pasteboard:board,fileURL:file)
  board.clearContents(); board.setString("first",forType:.string); store.poll()
  guard let clip = store.history.clips.first else { fatalError("text missing") }
  store.togglePin(clip.id); store.edit(clip.id,text:"edited")
  board.clearContents(); board.setString("second",forType:.string); store.poll()
  precondition(store.history.ordered.first?.id == clip.id)
  let restored = ClipboardStore(pasteboard:board,fileURL:file)
  precondition(restored.history.clips == store.history.clips)
  let edited = store.history.clips.first { $0.id == clip.id }!
  store.select(edited); precondition(board.string(forType:.string) == "edited")
  let image = NSImage(size:NSSize(width:2,height:2)); image.lockFocus(); NSColor.red.setFill(); NSRect(x:0,y:0,width:2,height:2).fill(); image.unlockFocus()
  board.clearContents(); board.writeObjects([image]); store.poll()
  precondition(store.history.clips.first?.kind == .image)
  store.select(store.history.clips.first!); precondition(NSImage(pasteboard:board) != nil)
  store.clear(); precondition(store.history.clips.count == 1 && store.history.clips[0].isPinned)
  let legacy = "{\"clips\":[{\"id\":\"9D42AFC8-6B55-4B7A-8743-A5A1EE593777\",\"kind\":\"text\",\"data\":\"b2xk\",\"createdAt\":0}],\"limit\":1}"
  var h = try JSONDecoder().decode(History.self,from:Data(legacy.utf8)); let id=h.clips[0].id; h.togglePin(id)
  h.add(Clip(kind:.text,data:Data("new".utf8))); h.add(Clip(kind:.text,data:Data("newer".utf8)))
  precondition(h.clips.count == 2 && h.ordered.first?.id == id)
  print("PASS: text, image, selection, pin, edit, persistence, legacy migration and limit")
 }
}
