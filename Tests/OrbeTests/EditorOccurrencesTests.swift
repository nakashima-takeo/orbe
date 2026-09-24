import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 出現の強調——キャレットの語の出現（50ms 後・打鍵で消え次の移動で出直す・焦点で出入り・俯瞰にも出る）と、選択文字列の
/// 他の出現（即時・本文の変更で 300ms 後に取り直す・俯瞰には出ない・検索バーと重ならない）。時間は差し替えた時計で進める。
///
/// 壊れると何が起きるか。打鍵のたびに語の地が点滅する。キャレットを動かしても出ない、端末へ移っても残る。選択の出現が
/// 検索の一致と二重に出る。本文を直した後に古い位置に地が残る。
@MainActor
final class EditorOccurrencesTests: OrbeTestCase {
  final class Clock {
    var word: (() -> Void)?
    var selection: (() -> Void)?
    var wordDelays: [TimeInterval] = []
    var selectionDelays: [TimeInterval] = []
  }

  /// 時計を差し替えて、テキスト面に焦点を置いた pane。本文は語の外（行頭の空白）から始める——焦点が入ると先頭の
  /// キャレットで語の出現を取りに行くので、語の上から始めるとその語の地が残る。
  func host(_ text: String, clock: Clock) throws -> OverviewHost {
    let hosted = try hostOverview(text)
    let occurrences = hosted.pane.occurrences
    occurrences.wordDelay.schedule = { delay, fire in
      clock.wordDelays.append(delay)
      clock.word = fire
    }
    occurrences.selectionDelay.schedule = { delay, fire in
      clock.selectionDelays.append(delay)
      clock.selection = fire
    }
    hosted.window.makeFirstResponder(hosted.document.surface.responder)
    pumpMain(until: { clock.word != nil }, "焦点が入ると語の出現を取りに行く")
    clock.word?()
    clock.word = nil
    return hosted
  }

  func caret(_ hosted: OverviewHost, _ location: Int) {
    hosted.document.surface.selectedRange = NSRange(location: location, length: 0)
  }

  func testWordOccurrencesAppearAfterFiftyMillisecondsAndReachTheOverview() throws {
    let clock = Clock()
    let text = " let foo = 1\nfoo + foobar\nbar(foo)\n"
    let hosted = try host(text, clock: clock)
    let occurrences = hosted.pane.occurrences
    caret(hosted, 6)
    XCTAssertEqual(occurrences.wordOccurrences, [], "すぐには出ない")
    XCTAssertEqual(clock.wordDelays.last, 0.05)
    try XCTUnwrap(clock.word)()
    let expected = [
      NSRange(location: 5, length: 3), NSRange(location: 13, length: 3),
      NSRange(location: 30, length: 3),
    ]
    XCTAssertEqual(occurrences.wordOccurrences, expected, "大小区別・語の境界つき（foobar は含まない）")
    XCTAssertEqual(hosted.pane.minimap.decorations.wordOccurrences, expected, "ミニマップへ")
    XCTAssertEqual(hosted.pane.scrollbar.decorations.wordOccurrences, expected, "スクロールバーへ")
  }

  /// キャレットが出ている範囲の中を動く間は取り直さない。語の外へ出れば消える。
  func testMovingInsideTheHighlightedWordDoesNotRequery() throws {
    let clock = Clock()
    let hosted = try host(" foo foo\nbar\n", clock: clock)
    caret(hosted, 2)
    try XCTUnwrap(clock.word)()
    clock.word = nil
    caret(hosted, 3)
    XCTAssertNil(clock.word, "同じ語の中の移動では取り直さない")
    caret(hosted, 10)
    XCTAssertEqual(hosted.pane.occurrences.wordOccurrences.count, 2, "取り直すまでは前の地が残る")
    try XCTUnwrap(clock.word)()
    XCTAssertEqual(hosted.pane.occurrences.wordOccurrences, [NSRange(location: 9, length: 3)])
  }

  /// 打鍵で消え、打鍵に伴うキャレットの移動では出ない。次の明示的な移動で出直す。
  func testTypingClearsAndOnlyAnExplicitMoveBringsThemBack() throws {
    let clock = Clock()
    let hosted = try host(" foo foo\n", clock: clock)
    let occurrences = hosted.pane.occurrences
    caret(hosted, 2)
    try XCTUnwrap(clock.word)()
    XCTAssertEqual(occurrences.wordOccurrences.count, 2)
    clock.word = nil
    hosted.document.surface.responder.keyDown(with: .key("x", []))
    XCTAssertEqual(occurrences.wordOccurrences, [], "打鍵で消える")
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    XCTAssertNil(clock.word, "打鍵に伴うキャレットの移動では出直さない")
    caret(hosted, 7)
    try XCTUnwrap(clock.word)()
    XCTAssertEqual(occurrences.wordOccurrences.count, 1, "明示的な移動で出直す（fxoo は別の語）")
  }

  /// 焦点がエディター面の外へ出ると消え、戻るとキャレットを動かさなくても出直す。検索バーへ移っても消えない。
  func testFocusLeavingTheFaceClearsAndReturningBringsThemBack() throws {
    let clock = Clock()
    let hosted = try host(" foo foo\n", clock: clock)
    let pane = hosted.pane
    caret(hosted, 2)
    try XCTUnwrap(clock.word)()
    XCTAssertEqual(pane.occurrences.wordOccurrences.count, 2)

    pane.showSearch()
    let bar = try XCTUnwrap(pane.searchBar)
    pumpMain(
      until: { (hosted.window.firstResponder as? NSView)?.isDescendant(of: bar) == true }, "バーへ")
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    XCTAssertEqual(pane.occurrences.wordOccurrences.count, 2, "検索バーはエディター面の中")
    pane.closeSearch()

    let outside = NSTextField(frame: .zero)
    hosted.tab.view.addSubview(outside)
    hosted.window.makeFirstResponder(outside)
    pumpMain(until: { pane.occurrences.wordOccurrences.isEmpty }, "面の外へ出れば消える")
    clock.word = nil
    hosted.window.makeFirstResponder(hosted.document.surface.responder)
    pumpMain(until: { clock.word != nil }, "戻れば取りに行く")
    try XCTUnwrap(clock.word)()
    XCTAssertEqual(pane.occurrences.wordOccurrences.count, 2, "キャレットを動かさなくても出直す")
  }

  /// 選択文字列の他の出現は即時に本文へ出て、俯瞰には出ない。語の出現は、選択が語をはみ出すと消える。
  func testSelectionOccurrencesShowImmediatelyInTheTextOnly() throws {
    let clock = Clock()
    let hosted = try host(" a.b x a.b y A.B\n", clock: clock)
    let pane = hosted.pane
    hosted.document.surface.selectedRange = NSRange(location: 1, length: 3)
    XCTAssertEqual(
      pane.occurrences.selectionOccurrences,
      [NSRange(location: 7, length: 3), NSRange(location: 13, length: 3)], "大小無視・自身は除く")
    clock.word?()
    XCTAssertEqual(pane.minimap.decorations.wordOccurrences, [], "俯瞰には出ない")
    hosted.document.surface.selectedRange = NSRange(location: 0, length: 0)
    XCTAssertEqual(pane.occurrences.selectionOccurrences, [], "選択が空なら出ない")
  }

  /// 本文を変えると、地は編集に合わせてずれ、300ms 後に取り直す。
  func testEditingRequeriesSelectionOccurrencesAfterThreeHundredMilliseconds() throws {
    let clock = Clock()
    let hosted = try host(" ab ab ab\n", clock: clock)
    let pane = hosted.pane
    hosted.document.surface.selectedRange = NSRange(location: 1, length: 2)
    XCTAssertEqual(pane.occurrences.selectionOccurrences.count, 2)
    hosted.document.surface.replaceAll(with: " ab ab ab ab\n")
    hosted.document.surface.selectedRange = NSRange(location: 1, length: 2)
    XCTAssertEqual(clock.selectionDelays.last, 0.3)
    try XCTUnwrap(clock.selection)()
    XCTAssertEqual(pane.occurrences.selectionOccurrences.count, 3, "取り直した")
  }

  /// 検索バーが同じ文字列を探している間は、選択文字列の出現を出さない（検索の一致と二重にしない）。
  func testSelectionOccurrencesStepAsideForTheFindBar() throws {
    let clock = Clock()
    let hosted = try host(" ab ab ab\n", clock: clock)
    let pane = hosted.pane
    pane.showSearch()
    pane.search.setNeedle("ab")
    XCTAssertEqual(hosted.document.surface.selectedRange.length, 2, "前提: 現在の一致が選択される")
    XCTAssertEqual(pane.occurrences.selectionOccurrences, [], "同じ文字列を検索中は出ない")
    pane.closeSearch()
    XCTAssertEqual(pane.occurrences.selectionOccurrences.count, 2, "バーを閉じれば出る")
  }
}
