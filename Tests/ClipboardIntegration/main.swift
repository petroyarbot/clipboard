import AppKit
import Foundation
@main struct Check {
 @MainActor static func main() throws {
  let board = NSPasteboard(name: .init("notchclip-test-\(UUID())")); defer { board.releaseGlobally() }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("notchclip-test-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at:root) }
  let file = root.appendingPathComponent("history.json")
  let store = ClipboardStore(pasteboard:board,fileURL:file)
  let htmlItem = NSPasteboardItem()
  let htmlText = "<section><h1>Новый текст</h1></section>"
  htmlItem.setString(htmlText, forType: .string)
  htmlItem.setString("<pre>&lt;section&gt;Новый текст&lt;/section&gt;</pre>", forType: .html)
  board.clearContents(); board.writeObjects([htmlItem])
  let htmlChange = board.changeCount
  store.poll()
  precondition(board.changeCount == htmlChange && board.string(forType: .string) == htmlText)
  precondition(store.history.clips.first.flatMap { String(data: $0.data, encoding: .utf8) } == htmlText)
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
  let link = Clip(kind: .text, data: Data("https://example.org/test".utf8))
  let ordinary = Clip(kind: .text, data: Data("обычный текст".utf8))
  precondition(link.linkURL?.host == "example.org" && ordinary.linkURL == nil)
  var h = try JSONDecoder().decode(History.self,from:Data(legacy.utf8)); let id=h.clips[0].id; h.togglePin(id)
  h.add(Clip(kind:.text,data:Data("new".utf8))); h.add(Clip(kind:.text,data:Data("newer".utf8)))
  precondition(h.clips.count == 2 && h.ordered.first?.id == id)
  let source = FileManager.default.temporaryDirectory.appendingPathComponent("notchclip-source-\(UUID()).txt")
  defer { try? FileManager.default.removeItem(at: source) }
  try Data("file fixture".utf8).write(to: source)
  try store.importFileSynchronously(source)
  guard let savedFile = store.history.clips.first, savedFile.kind == .file, let storedURL = store.managedFileURL(for: savedFile) else { fatalError("file not saved") }
  try FileManager.default.removeItem(at: source)
  let restoredBytes = try Data(contentsOf: storedURL)
  precondition(restoredBytes == Data("file fixture".utf8))
  store.select(savedFile)
  precondition(board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.count == 1)
  guard let export = store.exportFile(for: savedFile) else { fatalError("export missing") }
  precondition(export != storedURL)
  try FileManager.default.removeItem(at: export)
  precondition(FileManager.default.fileExists(atPath: storedURL.path))
  let restoredAgain = ClipboardStore(pasteboard: board, fileURL: file)
  precondition(restoredAgain.history.clips.contains(where: { $0.id == savedFile.id }))
  store.remove(savedFile.id)
  precondition(!FileManager.default.fileExists(atPath: storedURL.path))
  let copiedSource = root.appendingPathComponent("clipboard-fixture.txt")
  try Data("clipboard file".utf8).write(to: copiedSource)
  board.clearContents(); board.writeObjects([copiedSource as NSURL]); store.poll()
  let deadline = Date().addingTimeInterval(3)
  while !store.history.clips.contains(where: { $0.kind == .file }) && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
  }
  guard let copied = store.history.clips.first(where: { $0.kind == .file }), let copyURL = store.managedFileURL(for: copied) else { fatalError("pasteboard file missing") }
  let copiedBytes = try Data(contentsOf: copyURL)
  precondition(copiedBytes == Data("clipboard file".utf8))
  let pendingGeneration = store.importGeneration
  let pending = try FileVault.copy(copiedSource, into: store.filesDirectory)
  let pendingURL = store.managedFileURL(for: pending)!
  let beforeClear = board.changeCount
  store.clearAll()
  precondition(store.history.clips.isEmpty)
  precondition(!FileManager.default.fileExists(atPath: copyURL.path))
  precondition(board.changeCount == beforeClear)
  store.addImported(pending, generation: pendingGeneration)
  precondition(store.history.clips.isEmpty)
  precondition(!FileManager.default.fileExists(atPath: pendingURL.path))
  let afterClear = ClipboardStore(pasteboard: board, fileURL: file)
  precondition(afterClear.history.clips.isEmpty)
  print("PASS: HTML, text, images, files, pinning, complete clear, in-flight import and persistence")
 }
}
