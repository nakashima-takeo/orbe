import AppKit
import XCTest

@testable import Orbe

/// 面の中身——焦点の文書があればそのテキスト面が全面に載り、焦点の行き先とクリックの受け方が変わる。
/// ⌘S は焦点の文書を保存し、テキスト面が first responder になると面の記憶がエディターへ移る。
///
/// 壊れると何が起きるか。文書があるのに pane が焦点の行き先だと打鍵がテキスト面に届かない。hitTest が
/// self 固定のままだとテキスト面をクリックできない。テキスト面の焦点がタブに上がらないと分割中に
/// エディターを触っても焦点帯とドットが端末を指したまま。
@MainActor
final class EditorPaneViewTests: OrbeTestCase {
  private func file(_ name: String, _ text: String) throws -> URL {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
  }

  private func hosted(_ tab: TerminalTab, focus: Face = .editor) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = tab.view
    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: focus), animated: false)
    tab.view.layoutSubtreeIfNeeded()
    return window
  }

  func testShowingADocumentMountsItsSurfaceAndMovesTheFocusTarget() throws {
    let tab = TerminalTab(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hosted(tab)
    window.makeFirstResponder(pane)
    XCTAssertTrue(tab.focusTarget === pane, "空状態の行き先は pane")

    let document = try XCTUnwrap(try tab.editor.open(try file("a.swift", "let a = 1\n")))
    XCTAssertTrue(pane.document === document, "セッションの変化が器へ写る")
    XCTAssertTrue(document.surface.view.superview === pane)
    XCTAssertEqual(document.surface.view.frame.size, pane.bounds.size, "面いっぱい")
    XCTAssertTrue(tab.focusTarget === document.surface.responder, "行き先はテキスト面")
    XCTAssertTrue(window.firstResponder === document.surface.responder, "配下にあった焦点は行き先へ移る")

    let point = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: pane.superview)
    XCTAssertFalse(pane.hitTest(point) === pane, "文書を見せている間は中身がクリックを受ける")

    tab.editor.close(document)
    XCTAssertNil(pane.document)
    XCTAssertNil(document.surface.view.superview)
    XCTAssertTrue(tab.focusTarget === pane)
    XCTAssertTrue(pane.hitTest(point) === pane, "空状態では面自身が受ける")
    window.orderOut(nil)
  }

  func testSurfaceFocusMovesTheTabsFocusToTheEditor() throws {
    let tab = TerminalTab(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let document = try tab.editor.open(try file("b.txt", "x"))
    let window = hosted(tab, focus: .terminal)
    XCTAssertEqual(tab.faces.focus, .terminal)

    window.makeFirstResponder(document.surface.responder)
    XCTAssertEqual(tab.faces.focus, .editor, "テキスト面の焦点が面の記憶へ写る")
    window.orderOut(nil)
  }

  /// 文書を切り替えると見せる面が入れ替わり、それぞれの文書の本文・undo はその文書の面に残る
  /// （面を 1 つ使い回して本文を差し替えていれば、戻ったときに undo も本文も失われる）。
  func testSwitchingDocumentsSwapsTheSurfacesAndKeepsEachDocumentsState() throws {
    let tab = TerminalTab(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hosted(tab)
    let first = try tab.editor.open(try file("one.txt", "one"))
    let second = try tab.editor.open(try file("two.txt", "two"))
    window.makeFirstResponder(second.surface.responder)

    first.surface.responder.keyDown(with: .key("X", []))
    XCTAssertEqual(first.surface.text, "Xone")
    XCTAssertTrue(pane.document === second, "見せているのは焦点の文書の面")
    XCTAssertNil(first.surface.view.superview, "焦点でない文書の面は外れている")

    tab.editor.activate(first)
    XCTAssertTrue(pane.document === first)
    XCTAssertTrue(first.surface.view.superview === pane)
    XCTAssertNil(second.surface.view.superview)
    XCTAssertEqual(first.surface.text, "Xone", "戻っても本文はその文書の面に残っている")

    first.surface.responder.undoManager?.undo()
    XCTAssertEqual(first.surface.text, "one", "undo 履歴も文書ごとに残っている")
    window.orderOut(nil)
  }

  /// 見せる文書が入れ替わるとき、面の中にあった焦点は新しい行き先（次の文書の面・空状態なら面自身）へ移る。
  /// 前の面を外すと AppKit が first responder を窓へ戻すので、「中にあった」は外す前に取っていなければ
  /// ならない——外した後に見ると焦点は窓に落ちたままになり、切り替えても閉じても打鍵の行き先が消える。
  func testSwappingTheShownDocumentKeepsTheFocusInsideThePane() throws {
    let tab = TerminalTab(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hosted(tab)
    let first = try tab.editor.open(try file("p.txt", "p"))
    let second = try tab.editor.open(try file("q.txt", "q"))
    window.makeFirstResponder(second.surface.responder)

    tab.editor.activate(first)
    XCTAssertTrue(window.firstResponder === first.surface.responder, "切り替えた先の面へ移る")

    tab.editor.close(first)
    XCTAssertTrue(window.firstResponder === second.surface.responder, "閉じたら残る文書の面へ移る")

    tab.editor.close(second)
    XCTAssertTrue(window.firstResponder === tab.view.editor, "最後の文書を閉じたら面自身へ")
    window.orderOut(nil)
  }

  /// 面の外（端末）に焦点があるときに文書を開いても、焦点は奪わない。
  func testOpeningADocumentDoesNotStealFocusFromOutsideThePane() throws {
    let tab = TerminalTab(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hosted(tab, focus: .terminal)
    let outsider = NSTextField(frame: .zero)
    tab.view.addSubview(outsider)
    window.makeFirstResponder(outsider)

    let document = try tab.editor.open(try file("d.txt", "x"))

    XCTAssertTrue(tab.view.editor.document === document, "面の中身は入れ替わる")
    XCTAssertFalse(
      window.firstResponder === document.surface.responder, "面の外にある焦点は動かさない")
    window.orderOut(nil)
  }

  func testCommandSSavesTheActiveDocument() throws {
    let tab = TerminalTab(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let url = try file("c.txt", "abc")
    let document = try tab.editor.open(url)
    let window = hosted(tab)
    window.makeFirstResponder(document.surface.responder)
    document.surface.responder.perform(Selector(("insertText:")), with: "Z")
    XCTAssertTrue(document.isDirty)

    XCTAssertTrue(tab.view.editor.performKeyEquivalent(with: .key("s")))
    XCTAssertFalse(document.isDirty)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Zabc")
    window.orderOut(nil)
  }
}
