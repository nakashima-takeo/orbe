import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// ファイル内検索の起点——表示中の ⌘F の取り直し、Enter・⇧Enter と検索語を打つたびの行き先、本文の Esc。基準は
/// VS Code の既定（`FindController` / `FindModel`）。
///
/// 壊れると何が起きるか。表示中に ⌘F を押しても検索語が今の選択に変わらず、入力欄を打ち直せない。キャレットが一致の中に
/// あるとき ⇧Enter が同じ一致に留まる。検索語を消して打ち直すと、開いたときの位置でなく検索が選んだ位置から探す。本文で
/// Esc を押してもバーが閉じない。
extension EditorSearchTests {
  /// バーが出ている間の ⌘F は、押すたびに種で needle を取り直して入力欄を全選択する（選択は動かさない）。種が無い
  /// （改行をまたぐ選択・語の外）なら前の needle のまま全選択する。VS Code と同じ。
  func testCommandFWhileTheBarIsShownReseedsAndSelectsTheField() throws {
    let hosted = try host("alpha beta\ngamma\nalpha\n")
    let pane = hosted.pane
    let document = hosted.document
    document.surface.selectedRange = NSRange(location: 1, length: 0)
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("f")))
    let bar = try XCTUnwrap(pane.searchBar)
    func field() -> NSTextView? {
      (hosted.window.firstResponder as? NSTextView).flatMap { $0.isDescendant(of: bar) ? $0 : nil }
    }
    pumpMain(until: { field() != nil }, "入力欄に焦点")

    hosted.window.makeFirstResponder(document.surface.responder)
    document.surface.selectedRange = NSRange(location: 12, length: 0)
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("f")))
    XCTAssertEqual(pane.search.needle, "gamma", "キャレットの語で取り直す")
    pumpMain(
      until: {
        bar.needle == "gamma" && field()?.selectedRange() == NSRange(location: 0, length: 5)
      },
      "バーへ写り、全選択")
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 12, length: 0), "選択は動かない")

    document.surface.selectedRange = NSRange(location: 2, length: 12)
    try XCTUnwrap(field()).setSelectedRange(NSRange(location: 5, length: 0))
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("f")))
    XCTAssertEqual(pane.search.needle, "gamma", "種が無ければ前の needle")
    XCTAssertEqual(field()?.selectedRange(), NSRange(location: 0, length: 5), "焦点のある入力欄も全選択")
  }

  /// Enter は選択の終わりから、⇧Enter は選択の先頭から次・前の一致へ（キャレットが一致の中ならその一致を飛ばす）。
  /// VS Code `moveToNextMatch` / `moveToPrevMatch` と同じ起点。
  func testEnterStartsFromTheSelectionEndAndShiftEnterFromItsStart() throws {
    let hosted = try host("foo foo foo\n")
    let pane = hosted.pane
    let document = hosted.document
    document.surface.selectedRange = NSRange(location: 5, length: 0)
    pane.showSearch()
    XCTAssertEqual(pane.search.needle, "foo")
    pane.search.previous()
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 0, length: 3), "中の一致を飛ばして前へ")

    document.surface.selectedRange = NSRange(location: 0, length: 6)
    pane.search.next()
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 8, length: 3), "選択の終わりから次へ")
  }

  /// 検索語を打つたびに選ぶ一致は、検索が選んだのではない最後のキャレットから探す——打ち直して短くしても、開いた
  /// ときのキャレットから選び直す（VS Code の start position）。本文でキャレットを動かせば、そこが起点になる。
  func testRetypingTheNeedleSearchesFromTheCaretBeforeTheSearchMovedIt() throws {
    let hosted = try host("- a ab a\n")
    let pane = hosted.pane
    let document = hosted.document
    document.surface.selectedRange = NSRange(location: 0, length: 0)
    pane.showSearch()
    XCTAssertEqual(pane.search.needle, "", "前提: 種が無い")
    pane.search.setNeedle("a")
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 2, length: 1))
    pane.search.setNeedle("ab")
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 4, length: 2))
    pane.search.setNeedle("a")
    XCTAssertEqual(
      document.surface.selectedRange, NSRange(location: 2, length: 1), "開いたときのキャレットから")

    document.surface.selectedRange = NSRange(location: 5, length: 0)
    pane.search.setNeedle("ab")
    pane.search.setNeedle("a")
    XCTAssertEqual(
      document.surface.selectedRange, NSRange(location: 7, length: 1), "本文で動かしたキャレットから")
  }

  /// 本文に焦点がある間の Esc（変換中でない）はバーを閉じる。VS Code と同じ。
  func testEscapeInTheTextClosesTheBar() throws {
    let hosted = try host("one two\n")
    let pane = hosted.pane
    pane.showSearch()
    hosted.window.makeFirstResponder(hosted.document.surface.responder)
    let escape = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: hosted.window.windowNumber, context: nil, characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    hosted.window.sendEvent(escape)
    XCTAssertNil(pane.searchBar, "閉じる")
    XCTAssertTrue(hosted.window.firstResponder === hosted.document.surface.responder, "焦点は本文のまま")
  }
}
