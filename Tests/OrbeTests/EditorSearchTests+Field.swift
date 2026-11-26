import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 上のバーのファイル内検索の欄（本物の入力欄 `EditorTextField`）に、キーの押下とマウスの押下を届けて確かめる——欄に打った字で
/// 探し、↵ で次・⇧↵ で前の一致へ移り、esc で欄が消える（変換中の esc では消えない）。本文から欄を押せば、焦点が欄に入る。
///
/// 壊れると何が起きるか。欄に字を打っても一致が出ない。↵ で次の一致へ進まない・⇧↵ で前へ戻らない。欄の esc で欄が消えない。
/// 日本語で検索語を打つ途中の esc で、変換を取り消すつもりが欄ごと消える。
/// 本文を押した後に欄を押しても焦点が入らず、⌘F を押し直すしかない。
extension EditorSearchTests {
  /// キーの押下（窓の番号つき）。
  private func key(_ characters: String, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow)
    -> NSEvent
  {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: false,
      keyCode: characters == "\u{1b}" ? 53 : 36)!
  }

  /// 欄に打った字で探し、欄の ↵ は次、⇧↵ は前の一致を選び、欄の esc は欄を消す（閉じた後の焦点と選択は
  /// `testClosingKeepsTheSelectionAndReturnsFocusToTheText`）。変換中の esc では欄は消えない。
  func testTypingInTheFieldFindsAndItsKeysStepAndClose() throws {
    // 先頭のキャレットは語の上に無いので、⌘F の種は無い。
    let hosted = try host(" one one one\n")
    let pane = hosted.pane
    let surface = hosted.document.surface
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("f")))
    pumpMain(until: { self.focusIsInFindField(hosted) }, "欄に焦点")
    let field = try XCTUnwrap(hosted.window.firstResponder as? NSTextView)

    field.insertText("one", replacementRange: NSRange(location: 0, length: 0))
    pumpMain(until: { pane.search.matches.count == 3 }, "打った字で探す")
    XCTAssertEqual(surface.selectedRange, NSRange(location: 1, length: 3), "前提: 最初の一致を選ぶ")

    deliverKeyDown(key("\r", in: hosted.window), to: hosted.window)
    pumpMain(until: { surface.selectedRange == NSRange(location: 5, length: 3) }, "↵ で次の一致")
    deliverKeyDown(key("\r", .shift, in: hosted.window), to: hosted.window)
    pumpMain(until: { surface.selectedRange == NSRange(location: 1, length: 3) }, "⇧↵ で前の一致")

    // 欄に変換中の字を置く（IME の打鍵と同じ口）。
    let end = NSRange(location: field.string.utf16.count, length: 0)
    field.setSelectedRange(end)
    field.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: end)
    deliverKeyDown(key("\u{1b}", in: hosted.window), to: hosted.window)
    flush(hosted.window)
    XCTAssertNotNil(pane.findField.model, "変換中の esc では欄は消えない")
    field.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: end)

    // 変換中の esc で欄が残ることは、esc を送った直後に確かめた。対にするため、ここでも欄が消えることを、esc を送った直後に
    // 確かめる（消えるのを待たない）。
    deliverKeyDown(key("\u{1b}", in: hosted.window), to: hosted.window)
    flush(hosted.window)
    XCTAssertNil(pane.findField.model, "esc で欄が消える")
  }

  /// 本文に焦点がある間に欄を押すと、焦点が欄に入る。
  func testPressingTheFieldFromTheTextFocusesIt() throws {
    let hosted = try host(" one one\n")
    let pane = hosted.pane
    placeOffscreen(hosted.window)
    pane.showSearch()
    pumpMain(until: { self.focusIsInFindField(hosted) }, "前提: 欄に焦点")
    hosted.window.makeFirstResponder(hosted.document.surface.responder)
    pumpMain(until: { pane.findField.isFocused == false }, "前提: 焦点は本文")
    let input = try XCTUnwrap(findFieldView(pane))
    let frame = pane.convert(input.bounds, from: input)

    try click(pane, at: NSPoint(x: frame.midX, y: frame.midY))
    pumpMain(until: { self.focusIsInFindField(hosted) }, "押した欄に焦点が入る")
  }
}
