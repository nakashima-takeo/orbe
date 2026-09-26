import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 出現の強調——キャレットの語の出現（50ms 後・打鍵で消え次の移動で出直す・焦点で出入り・俯瞰にも出る）と、選択文字列の
/// 他の出現（選択の変化で即時・俯瞰には出ない・検索バーと重ならない）。どちらも本文に地として出る。時間は差し替えた時計で
/// 進め、出現を探す裏の仕事は追いつくのを待つ。
///
/// 壊れると何が起きるか。打鍵のたびに語の地が点滅する。キャレットを動かしても出ない、端末へ移っても残る。選択の出現が
/// 検索の一致と二重に出る。本文を直した後に古い位置に地が残る。
@MainActor
final class EditorOccurrencesTests: OrbeTestCase {
  final class Clock {
    var word: (() -> Void)?
    var wordDelays: [TimeInterval] = []
  }

  /// 時計を差し替えて、テキスト面に焦点を置いた pane。本文は語の外（行頭の空白）から始める——焦点が入ると先頭の
  /// キャレットで語の出現を取りに行くので、語の上から始めるとその語の地が残る。
  func host(_ text: String, clock: Clock) throws -> OverviewHost {
    let hosted = try hostOverview(text)
    let occurrences = hosted.pane.occurrences
    let document = hosted.document
    occurrences.wordDelay.schedule = { delay, fire in
      clock.wordDelays.append(delay)
      clock.word = {
        fire()
        document.waitUntilCaughtUp()
      }
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

  /// 本文の行 `row`（0 始まり）・桁 `column` のセルの上端寄り（字の上の、地だけがある所。pane の座標）。
  func groundPoint(_ hosted: OverviewHost, row: Int, column: Int) -> NSPoint {
    let style = EditorStyle.make()
    let surface = hosted.document.surface.view
    let origin = hosted.pane.convert(surface.bounds, from: surface).origin
    let cell = (" " as NSString).size(withAttributes: [.font: style.font]).width
    return NSPoint(
      x: origin.x + style.gutterWidth + style.marks.gutterWidth + (CGFloat(column) + 0.5) * cell,
      y: origin.y + style.topInset + CGFloat(row) * style.lineHeight + 1)
  }

  func groundColor(_ probe: PaneProbe, _ point: NSPoint) throws -> [Int] {
    try probe.rgb(point.x, y: point.y)
  }

  /// 語の出現は 50ms 後に本文の地として出て、スクロールバーの中央レーンとミニマップの行にも描かれる。
  func testWordOccurrencesAppearAfterFiftyMillisecondsAndReachTheOverview() throws {
    let clock = Clock()
    let text = " let foo = 1\nfoo + foobar\nbar(foo)\n"
    let hosted = try host(text, clock: clock)
    let pane = hosted.pane
    let occurrences = pane.occurrences
    caret(hosted, 6)
    XCTAssertEqual(occurrences.wordOccurrences, [], "すぐには出ない")
    XCTAssertEqual(clock.wordDelays.last, 0.05)
    let occurrence = groundPoint(hosted, row: 1, column: 1)
    let plain = groundPoint(hosted, row: 1, column: 4)
    XCTAssertTrue(
      PaneProbe.same(
        try groundColor(PaneProbe(pane), occurrence), try groundColor(PaneProbe(pane), plain)),
      "前提: 出る前は地のまま")
    try XCTUnwrap(clock.word)()
    let expected = [
      NSRange(location: 5, length: 3), NSRange(location: 13, length: 3),
      NSRange(location: 30, length: 3),
    ]
    XCTAssertEqual(occurrences.wordOccurrences, expected, "大小区別・語の境界つき（foobar は含まない）")
    _ = try probe(pane) {
      try !PaneProbe.same(self.groundColor($0, occurrence), self.groundColor($0, plain))
    }

    let bar = pane.scrollbar
    let scale = hosted.window.backingScaleFactor
    let ruler = OverviewRuler(
      lineCount: hosted.document.text.lineCount,
      visibleLines: hosted.document.viewportLines.visible, height: bar.bounds.height,
      scale: scale)
    let center = OverviewRuler.lane(.center, width: 14, scale: scale)
    let laneX = (CGFloat(center.x) + CGFloat(center.width) / 2) / scale
    func markY(_ row: Int) -> CGFloat {
      let span = ruler.spans([row...row])[0]
      return CGFloat(span.y1 + span.y2) / 2 / scale
    }
    let marks = try ViewPixels(bar)
    XCTAssertGreaterThan(marks.color(laneX, markY(1)).alphaComponent, 0.5, "スクロールバーの中央レーンに印")
    XCTAssertEqual(marks.color(laneX, markY(3)).alphaComponent, 0, "出現の無い行には無い")

    let minimap = pane.minimap
    let rows = try ViewPixels(minimap)
    XCTAssertGreaterThan(
      rows.color(minimap.bounds.width - 4, 1 * 2 + 1).alphaComponent, 0, "ミニマップの行の地")
    XCTAssertEqual(rows.color(minimap.bounds.width - 4, 3 * 2 + 1).alphaComponent, 0)
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

  /// 焦点が本文と検索バーの外へ出ると消え、戻るとキャレットを動かさなくても出直す。検索バーへ移っても消えない。
  func testFocusLeavingTheFaceClearsAndReturningBringsThemBack() throws {
    let clock = Clock()
    let hosted = try host(" foo foo\n", clock: clock)
    let pane = hosted.pane
    caret(hosted, 2)
    try XCTUnwrap(clock.word)()
    XCTAssertEqual(pane.occurrences.wordOccurrences.count, 2)

    pane.showSearch()
    catchUp(hosted.document)
    let bar = try XCTUnwrap(pane.searchBar)
    pumpMain(
      until: { (hosted.window.firstResponder as? NSView)?.isDescendant(of: bar) == true }, "バーへ")
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    XCTAssertEqual(pane.occurrences.wordOccurrences.count, 2, "検索バーへ移っても消えない")
    pane.closeSearch()
    catchUp(hosted.document)

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

  /// 検索バーから本文と検索バーの外へ焦点が移っても消える（テキスト面の焦点は変わらない経路）。
  func testFocusLeavingFromTheFindBarClears() throws {
    let clock = Clock()
    let hosted = try host(" foo foo\n", clock: clock)
    let pane = hosted.pane
    caret(hosted, 2)
    try XCTUnwrap(clock.word)()
    pane.showSearch()
    catchUp(hosted.document)
    let bar = try XCTUnwrap(pane.searchBar)
    pumpMain(
      until: { (hosted.window.firstResponder as? NSView)?.isDescendant(of: bar) == true }, "バーへ")
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    XCTAssertEqual(pane.occurrences.wordOccurrences.count, 2, "前提: バーにいる間は残る")
    let outside = NSTextField(frame: .zero)
    hosted.tab.view.addSubview(outside)
    hosted.window.makeFirstResponder(outside)
    pumpMain(until: { pane.occurrences.wordOccurrences.isEmpty }, "バーから外へ出れば消える")
    XCTAssertNotNil(pane.searchBar, "バーは開いたまま")
  }

  /// 選択文字列の他の出現は即時に本文へ出る。選択が語をはみ出すと語の出現は出ない。
  func testSelectionOccurrencesShowImmediatelyInTheTextOnly() throws {
    let clock = Clock()
    let hosted = try host(" a.b x a.b y A.B\n", clock: clock)
    let pane = hosted.pane
    let occurrence = groundPoint(hosted, row: 0, column: 8)
    let plain = groundPoint(hosted, row: 0, column: 5)
    hosted.document.surface.selectedRange = NSRange(location: 1, length: 3)
    catchUp(hosted.document)
    XCTAssertEqual(
      pane.occurrences.selectionOccurrences,
      [NSRange(location: 7, length: 3), NSRange(location: 13, length: 3)], "大小無視・自身は除く")
    _ = try probe(pane) {
      try !PaneProbe.same(self.groundColor($0, occurrence), self.groundColor($0, plain))
    }
    clock.word?()
    XCTAssertEqual(pane.minimap.decorations.wordOccurrences, [], "選択が語をはみ出すと語の出現は出ない")
    hosted.document.surface.selectedRange = NSRange(location: 0, length: 0)
    XCTAssertEqual(pane.occurrences.selectionOccurrences, [], "選択が空なら出ない")
    _ = try probe(pane) {
      try PaneProbe.same(self.groundColor($0, occurrence), self.groundColor($0, plain))
    }
  }

  /// 本文を変える操作は本文の変化の後に選択の変化を伴うので、選択文字列の出現はそこで取り直される（undo で選択が
  /// 戻ればすぐ出る）。
  func testSelectionOccurrencesFollowTheSelectionThatComesWithAnEdit() throws {
    let clock = Clock()
    let hosted = try host(" ab ab ab\n", clock: clock)
    let pane = hosted.pane
    let responder = hosted.document.surface.responder
    hosted.document.surface.selectedRange = NSRange(location: 1, length: 2)
    catchUp(hosted.document)
    XCTAssertEqual(pane.occurrences.selectionOccurrences.count, 2)
    responder.keyDown(with: .key("x", []))
    XCTAssertEqual(pane.occurrences.selectionOccurrences, [], "選択が消えれば消える")
    responder.undoManager?.undo()
    catchUp(hosted.document)
    XCTAssertEqual(hosted.document.surface.selectedRange, NSRange(location: 1, length: 2))
    XCTAssertEqual(pane.occurrences.selectionOccurrences.count, 2, "戻った選択で即座に取り直す")
    responder.perform(#selector(NSResponder.uppercaseWord(_:)), with: nil)
    catchUp(hosted.document)
    XCTAssertEqual(bodyText(hosted.document), " AB ab ab\n")
    XCTAssertEqual(
      pane.occurrences.selectionOccurrences,
      [NSRange(location: 4, length: 2), NSRange(location: 7, length: 2)], "大文字化の後の選択で取り直す")
  }

  /// キャレットを動かして 50ms の予約が残っている間に打つと、その予約は出ない（打鍵で消えた地を古い予約が出し直さない）。
  func testTypingCancelsAPendingWordQuery() throws {
    let clock = Clock()
    let hosted = try host(" foo foo\n", clock: clock)
    var pending: [() -> Void] = []
    hosted.pane.occurrences.wordDelay.schedule = { _, fire in pending.append(fire) }
    caret(hosted, 2)
    XCTAssertEqual(pending.count, 1, "前提: 予約がある")
    hosted.document.surface.responder.keyDown(with: .key("x", []))
    for fire in pending { fire() }
    XCTAssertEqual(hosted.pane.occurrences.wordOccurrences, [], "古い予約は何もしない")
  }

  /// 検索バーが同じ文字列を探している間は、選択文字列の出現を出さない（検索の一致と二重にしない）。
  func testSelectionOccurrencesStepAsideForTheFindBar() throws {
    let clock = Clock()
    let hosted = try host(" ab ab ab\n", clock: clock)
    let pane = hosted.pane
    pane.showSearch()
    catchUp(hosted.document)
    pane.search.setNeedle("ab")
    catchUp(hosted.document)
    XCTAssertEqual(hosted.document.surface.selectedRange.length, 2, "前提: 現在の一致が選択される")
    XCTAssertEqual(pane.occurrences.selectionOccurrences, [], "同じ文字列を検索中は出ない")
    pane.closeSearch()
    catchUp(hosted.document)
    XCTAssertEqual(pane.occurrences.selectionOccurrences.count, 2, "バーを閉じれば出る")
  }

  /// 語の出現を頼んだ後、結果が届く前に打鍵で消した問いの結果は、届いても出さない（打鍵のたびに地が点滅しない）。
  func testAWordQueryAnsweredAfterTypingDoesNotShow() throws {
    let clock = Clock()
    let hosted = try host(" foo foo\n", clock: clock)
    var ask: (() -> Void)?
    hosted.pane.occurrences.wordDelay.schedule = { _, fire in ask = fire }
    caret(hosted, 2)
    try XCTUnwrap(ask)()
    hosted.document.surface.responder.keyDown(with: .key("x", []))
    catchUp(hosted.document)
    XCTAssertEqual(hosted.pane.occurrences.wordOccurrences, [], "打鍵で取り消した問いの結果は出さない")
  }

  /// 選択文字列の出現を頼んだ後、結果が届く前に選択を畳めば、届いた結果は出さない。
  func testASelectionQueryAnsweredAfterCollapsingDoesNotShow() throws {
    let clock = Clock()
    let hosted = try host(" ab ab ab\n", clock: clock)
    hosted.document.surface.selectedRange = NSRange(location: 1, length: 2)
    hosted.document.surface.selectedRange = NSRange(location: 0, length: 0)
    catchUp(hosted.document)
    XCTAssertEqual(hosted.pane.occurrences.selectionOccurrences, [], "畳んだ選択の出現は戻らない")
  }
}
