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
  /// 一致が届いてから、起点以降の最初の一致を選んだうえでその次へ行う（同期で探したときと同じ行き先）——前の検索語の一致へ
  /// 飛ばず、届く速さで行き先が変わらない。
  func testEnterRightAfterRetypingSelectsTheFirstMatchThenStepsFromIt() throws {
    let hosted = try host(" a x ab ab\n")
    let pane = hosted.pane
    let document = hosted.document
    pane.showSearch()
    catchUp(pane)
    pane.search.setNeedle("a")
    catchUp(pane)
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 1, length: 1), "前提")

    pane.search.setNeedle("ab")
    XCTAssertEqual(pane.search.matches.map(\.location), [1, 5, 8], "届くまでは前の一致を出したまま")
    pane.search.next()
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 1, length: 1), "届く前は動かない")
    catchUp(pane)
    XCTAssertEqual(pane.search.matches.map(\.location), [5, 8])
    XCTAssertEqual(
      document.surface.selectedRange, NSRange(location: 8, length: 2),
      "最初の一致（5）の次の一致へ（前の選択 1 から進む 5 ではない）")
  }

  /// 同じく、届く前の ⇧Enter は、届いてから最初の一致を選んだうえでその前へ行う。
  func testShiftEnterRightAfterRetypingSelectsTheFirstMatchThenStepsBack() throws {
    let hosted = try host("ab x ab y ab z\n")
    let pane = hosted.pane
    let document = hosted.document
    document.surface.selectedRange = NSRange(location: 3, length: 0)
    pane.showSearch()
    catchUp(pane)
    document.surface.selectedRange = NSRange(location: 0, length: 0)
    pane.search.setNeedle("y")
    catchUp(pane)
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 8, length: 1), "前提")

    pane.search.setNeedle("ab")
    pane.search.previous()
    catchUp(pane)
    XCTAssertEqual(
      document.surface.selectedRange, NSRange(location: 10, length: 2),
      "最初の一致（0）の前へ循環（前の選択 8 から戻る 5 ではない）")
  }

  /// 一致を待っている間に Enter と ⇧Enter を続けて押すと、届いてから当てるのは最後に押した 1 回ぶんだけ。
  func testOnlyTheLastStepPressedWhileWaitingIsApplied() throws {
    let hosted = try host("x ab ab ab\n")
    let pane = hosted.pane
    let document = hosted.document
    pane.showSearch()
    catchUp(pane)
    pane.search.setNeedle("b")
    catchUp(pane)
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 3, length: 1), "前提")

    pane.search.setNeedle("ab")
    pane.search.next()
    pane.search.previous()
    catchUp(pane)
    XCTAssertEqual(
      document.surface.selectedRange, NSRange(location: 8, length: 2),
      "最初の一致（2）の前へ循環（Enter も当てれば 2 に戻り、先に押した Enter だけなら 5）")
  }

  /// 本文を編集して一致を取り直している間（問いは同じ）は待たない——Enter は、ずらした一致に対してその場で進む。
  func testEnterWhileRefreshingAfterAnEditStepsAtOnceOverTheShiftedMatches() throws {
    let hosted = try host("ab ab ab\n")
    let pane = hosted.pane
    let document = hosted.document
    pane.showSearch()
    catchUp(pane)
    pane.search.setNeedle("ab")
    catchUp(pane)
    hosted.window.makeFirstResponder(document.surface.responder)
    document.surface.selectedRange = NSRange(location: 0, length: 0)
    var refresh: (() -> Void)?
    pane.search.refreshDelay.schedule = { _, fire in refresh = fire }
    document.surface.responder.keyDown(with: .key("z", []))
    XCTAssertEqual(bodyText(document), "zab ab ab\n", "前提")
    try XCTUnwrap(refresh)()

    pane.search.next()
    XCTAssertEqual(
      document.surface.selectedRange, NSRange(location: 1, length: 2), "取り直しの結果を待たずに、ずらした一致へ")
  }

  /// 一致を待っている間に人が選択を動かせば、届いた一致はその選択を覆さない（後回しの選択と一歩は取り消す）。
  func testMovingTheSelectionWhileWaitingCancelsTheDeferredSelection() throws {
    let hosted = try host("x ab ab\n")
    let pane = hosted.pane
    let document = hosted.document
    pane.showSearch()
    catchUp(pane)
    pane.search.setNeedle("ab")
    pane.search.next()
    document.surface.selectedRange = NSRange(location: 1, length: 0)
    catchUp(pane)
    XCTAssertEqual(pane.search.matches.map(\.location), [2, 5], "一致は届く")
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 1, length: 0), "人の選択はそのまま")
  }

  /// 検索バーを開いたまま文書を切り替えると、新しい文書の一致が届くまで件数は前のまま（「一致なし」を出さない）。その間に
  /// 選択が動いても同じ。
  func testSwitchingDocumentsKeepsTheCountUntilTheNewMatchesArrive() throws {
    let hosted = try host("one two one\n")
    let pane = hosted.pane
    pane.showSearch()
    catchUp(pane)
    pane.search.setNeedle("one")
    catchUp(pane)
    let seen = counts(pane)
    let other = try hosted.tab.editor.open(try caseFile("t.txt", "one\n"))
    XCTAssertFalse(seen().contains { $0.1 == 0 }, "届く前に一致なしを出さない: \(seen())")
    other.surface.selectedRange = NSRange(location: 2, length: 0)
    XCTAssertFalse(seen().contains { $0.1 == 0 }, "届く前に選択が動いても一致なしを出さない: \(seen())")
    catchUp(pane)
    XCTAssertEqual(seen().last?.1, 1, "新しい文書の件数")
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
