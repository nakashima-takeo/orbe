import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// セッション——開く・同じファイルは焦点だけ・閉じると隣へ・未保存の有無・通知は 1 本・面を作れなければ開けない。
/// 仮の文書は高々 1 つで、仮で開けば同じ位置で入れ替わり、未保存になった瞬間・普通に開き直すと普通に戻る。
/// 面は本物を queries 無しで作る（色は要らない）。
///
/// 壊れると何が起きるか。同じファイルが 2 度開かれると undo と本文が 2 つに割れる。閉じたとき焦点が
/// 消えた文書に残ると器が外した面を指す。未保存の変化が通知に載らないと u4 のファイルタブに印が出ない。
/// 仮の文書が未保存のまま入れ替わると、編集が黙って消える。入れ替えが末尾へ動くと、見て回る間タブが跳ねる。
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

  /// `body` の間に `onChange` が上がった本数。操作ごとの差分で見る——累積の絶対値は、別の操作が
  /// 通知を 1 本増やしただけで、この仕様と関係なく落ちる。
  private func notifications(_ session: EditorSession, during body: () throws -> Void) rethrows
    -> Int
  {
    var count = 0
    session.onChange = { count += 1 }
    defer { session.onChange = nil }
    try body()
    return count
  }

  func testOpenActivateCloseAndNotify() throws {
    let session = EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
    let a = try file("a.txt", "a")
    let b = try file("b.txt", "b")

    let docA = try session.open(a, as: .pinned)
    let docB = try session.open(b, as: .pinned)
    XCTAssertTrue(session.activeDocument === docB)
    XCTAssertEqual(session.documents.count, 2)

    var reopened: EditorDocument?
    let reopenCount = try notifications(session) { reopened = try session.open(a, as: .pinned) }
    XCTAssertTrue(reopened === docA, "同じファイルは焦点を移すだけ")
    XCTAssertEqual(session.documents.count, 2)
    XCTAssertEqual(reopenCount, 1, "焦点が移ったので 1 本")

    XCTAssertEqual(notifications(session) { session.activate(docA) }, 0, "既に焦点なら通知しない")

    XCTAssertEqual(notifications(session) { session.close(docA) }, 1)
    XCTAssertTrue(session.activeDocument === docB, "焦点の文書を閉じれば隣へ")
    session.close(docB)
    XCTAssertNil(session.activeDocument)
  }

  /// テキスト面を作れない（Metal の装置が取れない）環境では、読めるファイルも開けない——読めないファイルと同じく
  /// エラーで返り、列・焦点・通知は変わらない。読めないファイルは面を作る前に読めないと返る。
  func testWithoutASurfaceNothingOpens() throws {
    let session = EditorSession(
      surfaces: EditorSurfaces(registry: LanguageRegistry(queriesRoot: nil), make: { nil }))
    let a = try file("a.txt", "a")
    let count = try notifications(session) {
      XCTAssertThrowsError(try session.open(a, as: .pinned)) {
        XCTAssertEqual($0 as? EditorSurfaceError, .noMetalDevice)
      }
    }
    XCTAssertEqual(count, 0)
    XCTAssertTrue(session.documents.isEmpty)
    XCTAssertNil(session.activeDocument)
    let missing = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent("missing.txt")
    XCTAssertThrowsError(try session.open(missing, as: .pinned)) {
      XCTAssertNotNil($0 as? EditorDocumentError, "読めないファイルは読めないと返る")
    }
  }

  func testUnsavedChangesAreNotified() throws {
    let session = EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
    let url = try file("c.txt", "hello")
    let document = try session.open(url, as: .pinned)
    var changes = 0
    session.onChange = { changes += 1 }

    XCTAssertTrue(session.documentsToDiscard().isEmpty)
    document.surface.responder.perform(Selector(("insertText:")), with: "!")
    XCTAssertTrue(document.isDirty)
    XCTAssertFalse(session.documentsToDiscard().isEmpty)
    XCTAssertEqual(changes, 1)

    try session.saveActive()
    XCTAssertTrue(session.documentsToDiscard().isEmpty)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "!hello")
    XCTAssertEqual(changes, 2)
  }

  /// 文書の識別は symlink を解いた実体——リンク経由と実体のパスで開いても同じ 1 文書で、保存
  /// （一時ファイルの rename）がリンクを通常ファイルに置き換えず実体へ届く。
  func testOpenResolvesSymlinksSoSavingReachesTheTarget() throws {
    let session = EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
    let target = try file("real.txt", "OLD")
    let link = target.deletingLastPathComponent().appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let viaLink = try session.open(link, as: .pinned)
    let viaTarget = try session.open(target, as: .pinned)
    XCTAssertTrue(viaLink === viaTarget, "同じ実体は 1 文書")
    XCTAssertEqual(session.documents.count, 1)
    XCTAssertEqual(viaLink.url, target.resolvingSymlinksInPath())

    viaLink.surface.responder.perform(Selector(("insertText:")), with: "NEW ")
    try session.saveActive()
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "NEW OLD", "実体へ書かれる")
    let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
    XCTAssertEqual(
      attributes[.type] as? FileAttributeType, .typeSymbolicLink, "リンクは通常ファイルにならない")
  }

  // MARK: - 仮の文書

  /// 仮で開くと、今の仮の文書を同じ位置で入れ替える（通知は 1 本）。仮の文書が無ければ末尾に足す。普通の文書は残る。
  func testAPreviewReplacesThePreviewInPlace() throws {
    let session = EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
    let a = try file("a.txt", "a")
    let b = try file("b.txt", "b")
    let c = try file("c.txt", "c")
    let docA = try session.open(a, as: .preview)
    XCTAssertTrue(session.preview === docA)
    try session.open(c, as: .pinned)

    var docB: EditorDocument?
    let count = try notifications(session) { docB = try session.open(b, as: .preview) }
    XCTAssertEqual(count, 1, "閉じる＋開くを 1 本で")
    XCTAssertEqual(
      session.documents.map(\.url.lastPathComponent), ["b.txt", "c.txt"], "仮の位置で入れ替わる")
    XCTAssertTrue(session.preview === docB)
    XCTAssertTrue(session.activeDocument === docB)

    session.close(try XCTUnwrap(docB))
    XCTAssertNil(session.preview, "閉じれば仮無し")
    try session.open(a, as: .preview)
    XCTAssertEqual(session.documents.map(\.url.lastPathComponent), ["c.txt", "a.txt"], "仮が無ければ末尾")
  }

  /// 開いている文書を仮で開き直しても焦点が移るだけで、普通の文書は普通のまま。普通に開き直すと仮の文書は普通になる。
  func testReopeningKeepsPinnedDocumentsAndPinsAPreview() throws {
    let session = EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
    let pinned = try session.open(try file("a.txt", "a"), as: .pinned)
    let preview = try session.open(try file("b.txt", "b"), as: .preview)

    XCTAssertTrue(try session.open(pinned.url, as: .preview) === pinned)
    XCTAssertTrue(session.preview === preview, "普通の文書は仮に下がらず、仮の文書も残る")
    XCTAssertTrue(session.activeDocument === pinned)

    XCTAssertEqual(try notifications(session) { try session.open(preview.url, as: .pinned) }, 1)
    XCTAssertNil(session.preview, "普通に開き直すと普通になる")
    XCTAssertEqual(session.documents.count, 2)
  }

  /// 仮の文書を固定する口は仮の文書だけに効き、仮でなければ通知もしない。
  func testPinOnlyPinsThePreview() throws {
    let session = EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
    let pinned = try session.open(try file("a.txt", "a"), as: .pinned)
    let preview = try session.open(try file("b.txt", "b"), as: .preview)
    XCTAssertEqual(notifications(session) { session.pin(pinned) }, 0)
    XCTAssertEqual(notifications(session) { session.pin(preview) }, 1)
    XCTAssertNil(session.preview)
    try session.open(try file("c.txt", "c"), as: .preview)
    XCTAssertEqual(session.documents.count, 3, "固定した文書は入れ替わらない")
  }

  /// 仮の文書は未保存になった瞬間に普通になり（通知は 1 本）、保存して未保存でなくなっても仮に戻らない。未編集の仮の文書は
  /// 保存しても仮のまま。
  func testAPreviewIsPinnedTheMomentItIsEdited() throws {
    let session = EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
    let saved = try session.open(try file("a.txt", "a"), as: .preview)
    try session.saveActive()
    XCTAssertTrue(session.preview === saved, "保存では普通にならない")

    let count = notifications(session) {
      saved.surface.responder.perform(Selector(("insertText:")), with: "!")
    }
    XCTAssertEqual(count, 1)
    XCTAssertNil(session.preview, "未保存になった瞬間に普通になる")
    try session.saveActive()
    XCTAssertNil(session.preview, "保存しても仮に戻らない")

    try session.open(try file("b.txt", "b"), as: .preview)
    XCTAssertEqual(session.documents.count, 2, "編集した文書は入れ替わらない")
  }

  /// 仮で開けないファイル（読めない・UTF-8 でない）は列も仮の文書も変えない。
  func testAPreviewThatCannotOpenKeepsThePreview() throws {
    let session = EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
    let preview = try session.open(try file("a.txt", "a"), as: .preview)
    let binary = try file("bin", "")
    try Data([0xff, 0xfe, 0xc3]).write(to: binary)
    let count = try notifications(session) {
      XCTAssertThrowsError(try session.open(binary, as: .preview))
    }
    XCTAssertEqual(count, 0)
    XCTAssertTrue(session.preview === preview)
    XCTAssertEqual(session.documents.count, 1)
  }
}
