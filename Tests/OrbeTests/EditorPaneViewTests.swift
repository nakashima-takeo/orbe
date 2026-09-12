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
