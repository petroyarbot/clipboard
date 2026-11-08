import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main struct DropIntegration {
 @MainActor static func main() throws {
  let board = NSPasteboard(name: .init("notchclip-drop-test-\(UUID())")); defer { board.releaseGlobally() }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("notchclip-drop-test-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ClipboardStore(pasteboard: NSPasteboard(name: .init("notchclip-general-test-\(UUID())")), fileURL: root.appendingPathComponent("history.json"))
  let importer = DropImporter(store: store)
  let permissionFixture = root.appendingPathComponent("permission-check.txt")
  try Data("fixture".utf8).write(to: permissionFixture)
  let readDenied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
  let writeDenied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
  precondition(!DropImporter.needsSourcePermission(writeDenied, source: permissionFixture), "writable source must not trigger source permission prompt for vault write error")
  try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: permissionFixture.path)
  precondition(DropImporter.needsSourcePermission(readDenied, source: permissionFixture))
  precondition(DropImporter.needsSourcePermission(writeDenied, source: permissionFixture), "source denial can surface as a copy write error")
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: permissionFixture.path)
  func awaitResult(_ predicate: () -> Bool) {
   let deadline = Date().addingTimeInterval(4)
   while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
  }
  for name in ["report.docx", "report.pdf", "notes.txt", "archive.zip"] {
   let source = root.appendingPathComponent(name); let bytes = Data("fixture for \(name)".utf8)
   try bytes.write(to: source)
   let count = store.history.clips.count
   board.clearContents(); precondition(board.writeObjects([source as NSURL])); precondition(importer.canAccept(board))
   precondition(importer.importPasteboard(board))
   awaitResult { store.history.clips.count > count || store.errorMessage != nil }
   guard let clip = store.history.clips.first, let stored = store.managedFileURL(for: clip), store.history.clips.count > count else { fatalError("\(name): no stored file, error=\(store.errorMessage ?? "none")") }
   precondition(clip.kind == .file && stored.lastPathComponent == name)
   let savedBytes = try Data(contentsOf: stored); precondition(savedBytes == bytes)
  }
  let first = root.appendingPathComponent("multi-one.docx")
  let second = root.appendingPathComponent("multi-two.pdf")
  try Data("one".utf8).write(to: first); try Data("two".utf8).write(to: second)
  let beforeMultiple = store.history.clips.count
  board.clearContents(); precondition(board.writeObjects([first as NSURL, second as NSURL])); precondition(importer.importPasteboard(board))
  awaitResult { store.history.clips.count >= beforeMultiple + 2 || store.errorMessage != nil }
  precondition(store.history.clips.count >= beforeMultiple + 2, "both files in a multiple drop should be imported")
  let multipleNames = Set(store.history.clips.compactMap { store.managedFileURL(for: $0)?.lastPathComponent })
  precondition(multipleNames.contains(first.lastPathComponent) && multipleNames.contains(second.lastPathComponent))
  let image = NSImage(size: NSSize(width: 2, height: 2)); image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
  let count = store.history.clips.count
  board.clearContents(); precondition(board.writeObjects([image])); precondition(importer.canAccept(board)); precondition(importer.importPasteboard(board))
  awaitResult { store.history.clips.count > count || store.errorMessage != nil }
  precondition(store.history.clips.count > count && store.history.clips.first?.kind == .image, "image not imported")
  store.errorMessage = nil
  let webURL = URL(string:"https://example.org/report.docx")!
  board.clearContents(); precondition(board.writeObjects([webURL as NSURL])); precondition(importer.canAccept(board)); precondition(importer.importPasteboard(board))
  precondition(store.history.clips.first?.linkURL == webURL, "web URL should remain a link")
  store.errorMessage = nil
  let missing = root.appendingPathComponent("missing.docx")
  board.clearContents(); precondition(board.writeObjects([missing as NSURL])); precondition(importer.canAccept(board)); precondition(importer.importPasteboard(board))
  awaitResult { store.errorMessage != nil }
  guard let error = store.errorMessage else { fatalError("missing file should report an error") }
  precondition(!error.localizedCaseInsensitiveContains("изображение"), "file error incorrectly calls it an image: \(error)")
  print("PASS: DOCX, PDF, TXT, ZIP, image, web link and missing-file error")
 }
}
