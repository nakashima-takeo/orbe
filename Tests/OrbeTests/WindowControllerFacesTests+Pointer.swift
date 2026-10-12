import AppKit
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// テキスト面は、窓の hit-test がその点で自分に解けるときだけポインタを持つ（手前に重なる取っ手に譲る）。実窓の view の
/// 重なり（chrome を含む）を通っても、取っ手の外の本文ではテキスト面がポインタを持つことを固定する。
///
/// 壊れると何が起きるか。窓の根からの hit-test が本文に届かなくなると（chrome の重なりの変更などで）、エディターの本文の
/// どこでも I ビームが出ず、⌘ の URL の下線も俯瞰のホバーも消える。
extension WindowControllerFacesTests {
  /// 実窓のエディター全面で、取っ手の外の本文の上ではテキスト面が I ビームを出す。
  @MainActor
  func testEditorBodyOwnsThePointerThroughTheWindow() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    tab.group.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    let document = try tab.group.editor.open(try caseFile("a.swift", "let a = 1\n"), as: .pinned)
    layout(wc)
    let pane = tab.group.view.editor
    let body = pane.convert(NSPoint(x: pane.bodyRect.midX, y: pane.bodyRect.midY), to: nil)
    let text = try engine(document).textView
    NSCursor.arrow.set()

    text.cursorUpdate(with: .mouse(.mouseMoved, at: body, in: wc.window))

    XCTAssertTrue(NSCursor.current === NSCursor.iBeam, "本文の上ではテキスト面がポインタを持つ")
  }
}
