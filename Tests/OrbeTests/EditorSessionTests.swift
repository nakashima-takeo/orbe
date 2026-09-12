import AppKit
import XCTest

@testable import Orbe

/// セッション——開く・同じファイルは焦点だけ・閉じると隣へ・未保存の有無・通知は 1 本。
/// 面は本物（STTextView）を queries 無しで作る（色は要らない）。
///
/// 壊れると何が起きるか。同じファイルが 2 度開かれると undo と本文が 2 つに割れる。閉じたとき焦点が
/// 消えた文書に残ると器が外した面を指す。未保存の変化が通知に載らないと u4 のファイルタブに印が出ない。
@MainActor
final class EditorSessionTests: OrbeTestCase {
  private func file(_ name: String, _ text: String) throws -> URL {
    let dir = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent(
      "files", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
  }

  func testOpenActivateCloseAndNotify() throws {
    let session = EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
    var changes = 0
    session.onChange = { changes += 1 }
    let a = try file("a.txt", "a")
    let b = try file("b.txt", "b")

    let docA = try session.open(a)
    let docB = try session.open(b)
    XCTAssertTrue(session.activeDocument === docB)
    XCTAssertEqual(session.documents.count, 2)
    XCTAssertEqual(changes, 2)

    XCTAssertTrue(try session.open(a) === docA, "同じファイルは焦点を移すだけ")
    XCTAssertTrue(session.activeDocument === docA)
    XCTAssertEqual(session.documents.count, 2)
    XCTAssertEqual(changes, 3)

    session.activate(docA)
    XCTAssertEqual(changes, 3, "既に焦点なら通知しない")

    session.close(docA)
    XCTAssertTrue(session.activeDocument === docB, "焦点の文書を閉じれば隣へ")
    session.close(docB)
    XCTAssertNil(session.activeDocument)
    XCTAssertEqual(changes, 5)
  }

  func testUnsavedChangesAreNotified() throws {
    let session = EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
    let url = try file("c.txt", "hello")
    let document = try session.open(url)
    var changes = 0
    session.onChange = { changes += 1 }

    XCTAssertFalse(session.hasUnsavedChanges)
    document.surface.responder.perform(Selector(("insertText:")), with: "!")
    XCTAssertTrue(document.isDirty)
    XCTAssertTrue(session.hasUnsavedChanges)
    XCTAssertEqual(changes, 1)

    try session.saveActive()
    XCTAssertFalse(session.hasUnsavedChanges)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "!hello")
    XCTAssertEqual(changes, 2)
  }

  func testOpenFailsForMissingOrBinary() throws {
    let session = EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
    XCTAssertThrowsError(try session.open(URL(fileURLWithPath: "/nonexistent/x.txt")))
    let binary = try file("bin", "")
    try Data([0xff, 0xfe, 0xc3]).write(to: binary)
    XCTAssertThrowsError(try session.open(binary))
    XCTAssertTrue(session.documents.isEmpty)
  }
}
