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
    catchUp(pane)
    let bar = try XCTUnwrap(pane.searchBar)
    func field() -> NSTextView? {
      (hosted.window.firstResponder as? NSTextView).flatMap { $0.isDescendant(of: bar) ? $0 : nil }
    }
    pumpMain(until: { field() != nil }, "入力欄に焦点")

    hosted.window.makeFirstResponder(document.surface.responder)
    document.surface.selectedRange = NSRange(location: 12, length: 0)
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("f")))
    catchUp(pane)
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
    catchUp(pane)
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
    catchUp(pane)
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
    catchUp(pane)
    XCTAssertEqual(pane.search.needle, "", "前提: 種が無い")
    pane.search.setNeedle("a")
    catchUp(pane)
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 2, length: 1))
    pane.search.setNeedle("ab")
    catchUp(pane)
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 4, length: 2))
    pane.search.setNeedle("a")
    catchUp(pane)
    XCTAssertEqual(
      document.surface.selectedRange, NSRange(location: 2, length: 1), "開いたときのキャレットから")

    document.surface.selectedRange = NSRange(location: 5, length: 0)
    pane.search.setNeedle("ab")
    catchUp(pane)
    pane.search.setNeedle("a")
    catchUp(pane)
    XCTAssertEqual(
      document.surface.selectedRange, NSRange(location: 7, length: 1), "本文で動かしたキャレットから")
  }

  /// 本文に焦点がある間の Esc（変換中でない）はバーを閉じる。VS Code と同じ。
  func testEscapeInTheTextClosesTheBar() throws {
    let hosted = try host("one two\n")
    let pane = hosted.pane
    pane.showSearch()
    catchUp(pane)
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

  /// 検索語を打ち換えた直後（新しい一致が届く前）は前の地と件数が出たままで、その間に押された Enter は、新しい検索語の
  /// 一致が届いてからその一致に対して行う——前の検索語の一致へ飛ばない。
  func testEnterRightAfterRetypingGoesToTheNewNeedlesMatch() throws {
    let hosted = try host("aa - bb\naa - bb\n")
    let pane = hosted.pane
    let document = hosted.document
    document.surface.selectedRange = NSRange(location: 3, length: 0)
    pane.showSearch()
    catchUp(pane)
    pane.search.setNeedle("aa")
    catchUp(pane)
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 8, length: 2), "前提")

    pane.search.setNeedle("bb")
    XCTAssertEqual(pane.search.matches.map(\.location), [0, 8], "届くまでは前の一致を出したまま")
    pane.search.next()
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 8, length: 2), "届く前は動かない")
    catchUp(pane)
    XCTAssertEqual(pane.search.matches.map(\.location), [5, 13])
    XCTAssertEqual(
      document.surface.selectedRange, NSRange(location: 13, length: 2),
      "新しい検索語の一致へ（前の検索語なら先頭の aa へ循環する）")
  }

  /// 検索語を打った後、一致が届く前にバーを閉じれば、届いた一致は出さない（閉じた検索の地が戻らない）。
  func testMatchesAnsweredAfterClosingDoNotShow() throws {
    let hosted = try host(" ab ab\n")
    let pane = hosted.pane
    pane.showSearch()
    catchUp(pane)
    XCTAssertEqual(pane.search.needle, "", "前提: 種が無い")
    pane.search.setNeedle("ab")
    pane.closeSearch()
    catchUp(pane)
    XCTAssertEqual(pane.search.matches, [], "閉じた検索の一致は戻らない")
  }
}
