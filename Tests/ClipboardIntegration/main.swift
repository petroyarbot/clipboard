import AppKit
import Foundation
@main struct Check {
 @MainActor static func main() throws {
  let board = NSPasteboard(name: .init("notchclip-test-\(UUID())")); defer { board.releaseGlobally() }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("notchclip-test-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at:root) }
  let file = root.appendingPathComponent("history.json")
  // Tests never write to the real ~/Downloads: every store gets this folder.
  let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
  func waitUntil(_ timeout: TimeInterval = 4, _ condition: () -> Bool) {
      let deadline = Date().addingTimeInterval(timeout)
      while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
  }
  let store = ClipboardStore(pasteboard:board,fileURL:file,downloadsDirectory:downloads)
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
  let restored = ClipboardStore(pasteboard:board,fileURL:file,downloadsDirectory:downloads)
  precondition(restored.history.clips == store.history.clips)
  let edited = store.history.clips.first { $0.id == clip.id }!
  store.select(edited); precondition(board.string(forType:.string) == "edited")
  let image = NSImage(size:NSSize(width:2,height:2)); image.lockFocus(); NSColor.red.setFill(); NSRect(x:0,y:0,width:2,height:2).fill(); image.unlockFocus()
  board.clearContents(); board.writeObjects([image]); store.poll()
  waitUntil { store.history.clips.first?.kind == .image }  // PNG conversion runs off the main actor
  precondition(store.history.clips.first?.kind == .image)
  store.select(store.history.clips.first!); precondition(NSImage(pasteboard:board) != nil)
  // Some apps include an unusable file URL alongside actual image data.
  let mixedImage = NSImage(size: NSSize(width: 2, height: 2))
  mixedImage.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); mixedImage.unlockFocus()
  let mixedItem = NSPasteboardItem()
  mixedItem.setString(root.absoluteString, forType: .fileURL)
  mixedItem.setData(mixedImage.tiffRepresentation!, forType: .tiff)
  let beforeMixed = store.history.clips.map(\.id)
  board.clearContents(); board.writeObjects([mixedItem]); store.poll()
  let mixedDeadline = Date().addingTimeInterval(3)
  while !store.history.clips.contains(where: { !beforeMixed.contains($0.id) && $0.kind == .image }) && Date() < mixedDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
  }
  precondition(store.history.clips.contains(where: { !beforeMixed.contains($0.id) && $0.kind == .image }))
  precondition(store.errorMessage == nil)
  // Telegram writes the URL and image as two pasteboard items, not one.
  let telegramImage = NSImage(size: NSSize(width: 3, height: 3))
  telegramImage.lockFocus(); NSColor.green.setFill(); NSRect(x: 0, y: 0, width: 3, height: 3).fill(); telegramImage.unlockFocus()
  let beforeTelegram = store.history.clips.map(\.id)
  board.clearContents(); precondition(board.writeObjects([root as NSURL, telegramImage])); store.poll()
  let telegramDeadline = Date().addingTimeInterval(3)
  while !store.history.clips.contains(where: { !beforeTelegram.contains($0.id) && $0.kind == .image }) && Date() < telegramDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
  }
  precondition(store.history.clips.contains(where: { !beforeTelegram.contains($0.id) && $0.kind == .image }))
  precondition(store.errorMessage == nil, "Telegram-style clipboard should not report a directory error")
  let permission = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
  precondition(ClipboardStore.shouldRetryDroppedFileAccess(permission, usedCachedBookmark: true, sourceReadable: false))
  precondition(!ClipboardStore.shouldRetryDroppedFileAccess(permission, usedCachedBookmark: false, sourceReadable: false))
  precondition(!ClipboardStore.shouldRetryDroppedFileAccess(permission, usedCachedBookmark: true, sourceReadable: true))
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
  // Unreadable file URL plus image bytes: the bytes are used silently.
  let lockedFile = root.appendingPathComponent("locked-photo.jpg")
  try Data("unreadable".utf8).write(to: lockedFile)
  try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedFile.path)
  let lockedImage = NSImage(size: NSSize(width: 2, height: 2)); lockedImage.lockFocus(); NSColor.orange.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); lockedImage.unlockFocus()
  let lockedItem = NSPasteboardItem()
  lockedItem.setString(lockedFile.absoluteString, forType: .fileURL)
  lockedItem.setData(lockedImage.tiffRepresentation!, forType: .tiff)
  store.errorMessage = nil
  let beforeLocked = store.history.clips.map(\.id)
  board.clearContents(); precondition(board.writeObjects([lockedItem]))
  store.poll()
  waitUntil { store.history.clips.contains { !beforeLocked.contains($0.id) && $0.kind == .image } }
  precondition(store.history.clips.contains { !beforeLocked.contains($0.id) && $0.kind == .image }, "unreadable file should fall back to image bytes")
  precondition(store.errorMessage == nil, "unreadable file with image bytes must not report an error: \(store.errorMessage ?? "")")
  // A folder URL imports the media files directly inside it, not the folder itself.
  // Under Desktop, a user folder: its files keep the file behavior (app storage would import them as images).
  let photos = root.appendingPathComponent("Desktop/Photos", isDirectory: true)
  try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
  let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAE0lEQVR4nGP4z8DwHwMDw38GhoYfAAB7CBBl1VdfNgAAAABJRU5ErkJggg==")!
  try tinyPNG.write(to: photos.appendingPathComponent("b-second.png"))
  try tinyPNG.write(to: photos.appendingPathComponent("a-first.png"))
  try Data("notes".utf8).write(to: photos.appendingPathComponent("notes.txt"))
  let beforeFolder = store.history.clips.map(\.id)
  store.errorMessage = nil
  board.clearContents(); precondition(board.writeObjects([photos as NSURL]))
  store.poll()
  waitUntil { store.history.clips.filter { !beforeFolder.contains($0.id) }.count >= 2 || store.errorMessage != nil }
  let folderClips = store.history.clips.filter { !beforeFolder.contains($0.id) }
  precondition(folderClips.count == 2 && folderClips.allSatisfy { $0.kind == .file }, "folder should import its two images only")
  precondition(Set(folderClips.compactMap { store.managedFileURL(for: $0)?.lastPathComponent }) == ["a-first.png", "b-second.png"])
  precondition(store.errorMessage == nil)
  // WebP bytes are converted to PNG before they are stored.
  let webp = Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEChA/wvQ/wIAAA==")!
  let webpItem = NSPasteboardItem()
  webpItem.setData(webp, forType: NSPasteboard.PasteboardType("org.webmproject.webp"))
  let beforeWebP = store.history.clips.map(\.id)
  board.clearContents(); precondition(board.writeObjects([webpItem]))
  store.poll()
  waitUntil { store.history.clips.contains { !beforeWebP.contains($0.id) && $0.kind == .image } }
  guard let webpClip = store.history.clips.first(where: { !beforeWebP.contains($0.id) && $0.kind == .image }) else { fatalError("webp bytes were not imported") }
  precondition(Array(webpClip.data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47], "webp clip must be stored as PNG")
  // Images from app storage become image clips, with or without an extension; user folders keep file clips with their extension.
  func jpeg(_ color: NSColor) -> Data {
      let image = NSImage(size: NSSize(width: 2, height: 2)); image.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
      return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .jpeg, properties: [:])!
  }
  func importOne(_ url: URL, into target: ClipboardStore) -> Clip? {
      let before = Set(target.history.clips.map(\.id))
      board.clearContents(); precondition(board.writeObjects([url as NSURL]))
      target.poll()
      waitUntil { target.history.clips.contains { !before.contains($0.id) } }
      return target.history.clips.first { !before.contains($0.id) }
  }
  UserDefaults.standard.removeObject(forKey: ClipboardStore.downloadsKey)
  let telegramDir = root.appendingPathComponent("Library/Group Containers/telegram", isDirectory: true)
  try FileManager.default.createDirectory(at: telegramDir, withIntermediateDirectories: true)
  let appPhoto = telegramDir.appendingPathComponent("photo-a.jpg")
  try jpeg(.purple).write(to: appPhoto)
  precondition(importOne(appPhoto, into: store)?.kind == .image, "JPEG in app storage must become an image clip")
  let appNoExtension = telegramDir.appendingPathComponent("telegram-cloud-photo-size-2-1-y")
  try jpeg(.orange).write(to: appNoExtension)
  precondition(importOne(appNoExtension, into: store)?.kind == .image, "extensionless JPEG in app storage must become an image clip")
  let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
  try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
  let desktopPhoto = desktop.appendingPathComponent("photo.jpg")
  try jpeg(.cyan).write(to: desktopPhoto)
  let desktopClip = importOne(desktopPhoto, into: store)
  precondition(desktopClip?.kind == .file, "JPEG on Desktop must stay a file clip")
  precondition(desktopClip.flatMap { store.managedFileURL(for: $0)?.lastPathComponent } == "photo.jpg", "Desktop file clip must keep .jpg")
  let desktopNoExtension = desktop.appendingPathComponent("scan-without-extension")
  try jpeg(.yellow).write(to: desktopNoExtension)
  let extDownloads = root.appendingPathComponent("DownloadsExt", isDirectory: true)
  let extStore = ClipboardStore(pasteboard: board, fileURL: root.appendingPathComponent("ext-history.json"), downloadsDirectory: extDownloads)
  let noExtClip = importOne(desktopNoExtension, into: extStore)
  precondition(noExtClip?.kind == .file, "extensionless JPEG on Desktop must stay a file clip")
  precondition(noExtClip.flatMap { extStore.managedFileURL(for: $0)?.lastPathComponent } == "scan-without-extension.jpg", "stored name must gain the sniffed .jpg")
  waitUntil { FileManager.default.fileExists(atPath: extDownloads.appendingPathComponent("scan-without-extension.jpg").path) }
  precondition(FileManager.default.fileExists(atPath: extDownloads.appendingPathComponent("scan-without-extension.jpg").path), "Downloads copy must keep the extension")
  let appDownloadStore = ClipboardStore(pasteboard: board, fileURL: root.appendingPathComponent("app-history.json"), downloadsDirectory: extDownloads)
  let appDownloadClip = importOne(appNoExtension, into: appDownloadStore)
  precondition(appDownloadClip?.kind == .image, "app-storage JPEG must become an image clip in a fresh history")
  waitUntil { ((try? FileManager.default.contentsOfDirectory(atPath: extDownloads.path)) ?? []).contains { $0.hasPrefix("NotchClip ") && $0.hasSuffix(".png") } }
  precondition(((try? FileManager.default.contentsOfDirectory(atPath: extDownloads.path)) ?? []).contains { $0.hasPrefix("NotchClip ") && $0.hasSuffix(".png") }, "image clip copy must use the NotchClip PNG name")
  // Downloads: unique names, no re-save on re-select, and nothing when the setting is off.
  let downloadsTest = root.appendingPathComponent("DownloadsTest", isDirectory: true)
  let dlStore = ClipboardStore(pasteboard: board, fileURL: root.appendingPathComponent("dl-history.json"), downloadsDirectory: downloadsTest)
  UserDefaults.standard.removeObject(forKey: ClipboardStore.downloadsKey)
  let sourceA = root.appendingPathComponent("report-src-a", isDirectory: true)
  let sourceB = root.appendingPathComponent("report-src-b", isDirectory: true)
  for dir in [sourceA, sourceB] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
  try Data("report one".utf8).write(to: sourceA.appendingPathComponent("report.txt"))
  try Data("report two".utf8).write(to: sourceB.appendingPathComponent("report.txt"))
  board.clearContents(); precondition(board.writeObjects([sourceA.appendingPathComponent("report.txt") as NSURL]))
  dlStore.poll()
  waitUntil { FileManager.default.fileExists(atPath: downloadsTest.appendingPathComponent("report.txt").path) }
  board.clearContents(); precondition(board.writeObjects([sourceB.appendingPathComponent("report.txt") as NSURL]))
  dlStore.poll()
  waitUntil { FileManager.default.fileExists(atPath: downloadsTest.appendingPathComponent("report 2.txt").path) }
  let secondReportBytes = try Data(contentsOf: downloadsTest.appendingPathComponent("report 2.txt"))
  precondition(secondReportBytes == Data("report two".utf8))
  guard let reportClip = dlStore.history.clips.first(where: { $0.kind == .file }) else { fatalError("report clip missing") }
  dlStore.select(reportClip)
  board.clearContents(); precondition(board.writeObjects([image]))
  dlStore.poll()
  waitUntil { ((try? FileManager.default.contentsOfDirectory(atPath: downloadsTest.path)) ?? []).contains { $0.hasPrefix("NotchClip ") } }
  let saved = try FileManager.default.contentsOfDirectory(atPath: downloadsTest.path).sorted()
  precondition(saved.count == 3 && saved.contains("report.txt") && saved.contains("report 2.txt") && saved.contains { $0.hasPrefix("NotchClip ") && $0.hasSuffix(".png") }, "unexpected Downloads contents after re-select: \(saved)")
  UserDefaults.standard.set(false, forKey: ClipboardStore.downloadsKey)
  let skipped = root.appendingPathComponent("skipped.txt"); try Data("skipped".utf8).write(to: skipped)
  let beforeSkipped = dlStore.history.clips.map(\.id)
  board.clearContents(); precondition(board.writeObjects([skipped as NSURL])); dlStore.poll()
  waitUntil { dlStore.history.clips.contains { !beforeSkipped.contains($0.id) } }
  UserDefaults.standard.removeObject(forKey: ClipboardStore.downloadsKey)
  let kept = root.appendingPathComponent("kept.txt"); try Data("kept".utf8).write(to: kept)
  board.clearContents(); precondition(board.writeObjects([kept as NSURL])); dlStore.poll()
  waitUntil { FileManager.default.fileExists(atPath: downloadsTest.appendingPathComponent("kept.txt").path) }
  precondition(!FileManager.default.fileExists(atPath: downloadsTest.appendingPathComponent("skipped.txt").path), "setting off must not save to Downloads")
  // Path check: only real descendants of Downloads count, not look-alike prefixes.
  precondition(ClipboardStore.isInside(downloadsTest.appendingPathComponent("x.txt"), directory: downloadsTest))
  precondition(!ClipboardStore.isInside(downloadsTest.appendingPathComponent("x.txt"), directory: downloadsTest.appendingPathComponent("Down")))
  precondition(!ClipboardStore.isInside(root.appendingPathComponent("x.txt"), directory: downloadsTest))
  // A file that already lives in Downloads is imported but not copied to Downloads a second time.
  let alreadyThere = downloadsTest.appendingPathComponent("already-here.txt")
  try Data("already".utf8).write(to: alreadyThere)
  let beforeAlready = dlStore.history.clips.map(\.id)
  board.clearContents(); precondition(board.writeObjects([alreadyThere as NSURL]))
  dlStore.poll()
  waitUntil { dlStore.history.clips.contains { !beforeAlready.contains($0.id) } }
  precondition(dlStore.history.clips.contains { !beforeAlready.contains($0.id) }, "file from Downloads should still enter history")
  RunLoop.current.run(until: Date().addingTimeInterval(0.3))
  let afterAlready = try FileManager.default.contentsOfDirectory(atPath: downloadsTest.path)
  precondition(!afterAlready.contains("already-here 2.txt"), "file already in Downloads must not be copied again: \(afterAlready)")
  // The same image again is deduplicated by History, so no second PNG is saved.
  let pngBefore = afterAlready.filter { $0.hasPrefix("NotchClip ") }.count
  board.clearContents(); precondition(board.writeObjects([image]))
  dlStore.poll()
  RunLoop.current.run(until: Date().addingTimeInterval(0.5))
  let pngAfter = try FileManager.default.contentsOfDirectory(atPath: downloadsTest.path).filter { $0.hasPrefix("NotchClip ") }.count
  precondition(dlStore.history.clips.filter { $0.kind == .image }.count == 1, "identical image must be deduplicated in history")
  precondition(pngAfter == pngBefore, "deduplicated image must not be saved to Downloads again")
  // Images are converted off the main actor, but the result still arrives through addImported.
  print("PASS: HTML, text, images, files, pinning, complete clear, in-flight import, persistence, unreadable-file fallback, folder import, WebP, Downloads copies, Downloads skips and image dedupe")
 }
}
