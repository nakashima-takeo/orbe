import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorText

/// 行番号の列で行を選ぶ——クリック・ドラッグ・⇧クリック（VS Code の既定）と、本文の外へ出たときの自動スクロール。
extension EditorLineNumbersTests {
  /// 列の中の点（x は列の左端から、y は文書の `row` 行目（1 始まり）の中ほど）で起きたマウスの出来事。
  private func mouse(
    _ type: NSEvent.EventType, _ opened: Opened, row: CGFloat, x: CGFloat = 20,
    _ flags: NSEvent.ModifierFlags = []
  ) throws -> NSEvent {
    let point = NSPoint(x: x, y: (row - 0.5) * style.lineHeight)
    return try XCTUnwrap(
      NSEvent.mouseEvent(
        with: type, location: opened.column.convert(point, to: nil), modifierFlags: flags,
        timestamp: 0, windowNumber: opened.window.windowNumber, context: nil, eventNumber: 0,
        clickCount: 1, pressure: 1))
  }

  private func click(_ opened: Opened, row: CGFloat, _ flags: NSEvent.ModifierFlags = []) throws {
    opened.column.mouseDown(with: try mouse(.leftMouseDown, opened, row: row, flags))
    opened.column.mouseUp(with: try mouse(.leftMouseUp, opened, row: row, flags))
  }

  private func range(of line: Int, in document: EditorDocument) -> NSRange {
    let start = document.lineIndex.start(ofRow: line - 1)
    return NSRange(location: start, length: document.lineIndex.end(ofRow: line - 1) - start)
  }

  /// 番号を押すとその行を改行まで選び、焦点はテキスト面へ移る。最終行は本文の終わりまで。
  func testClickingANumberSelectsTheLine() throws {
    let opened = try open(lines(20))
    let document = opened.document
    XCTAssertFalse(opened.window.firstResponder === document.surface.responder)
    try click(opened, row: 3)
    XCTAssertEqual(document.surface.selectedRange, range(of: 3, in: document))
    XCTAssertTrue(opened.window.firstResponder === document.surface.responder, "焦点はテキスト面へ")

    let tail = try open("a\nb")
    try click(tail, row: 2)
    XCTAssertEqual(tail.document.surface.selectedRange, NSRange(location: 2, length: 1), "最終行は末尾まで")
  }

  /// ドラッグは押した行を起点に行単位で伸ばす——下へは起点の行頭からポインタの行の次の行頭まで、上へはポインタの行頭から
  /// 起点の行の次の行頭まで（動く側の端は先頭）、戻れば起点の行だけ。
  func testDraggingExtendsByLinesFromThePressedLine() throws {
    let opened = try open(lines(20))
    let document = opened.document
    opened.column.mouseDown(with: try mouse(.leftMouseDown, opened, row: 4))
    opened.column.mouseDragged(with: try mouse(.leftMouseDragged, opened, row: 6))
    XCTAssertEqual(
      document.surface.selectedRange,
      NSUnionRange(range(of: 4, in: document), range(of: 6, in: document)))
    XCTAssertEqual(document.surface.caretLocation, range(of: 7, in: document).location, "動く側は下端")

    opened.column.mouseDragged(with: try mouse(.leftMouseDragged, opened, row: 2))
    XCTAssertEqual(
      document.surface.selectedRange,
      NSUnionRange(range(of: 2, in: document), range(of: 4, in: document)))
    XCTAssertEqual(document.surface.caretLocation, range(of: 2, in: document).location, "動く側は先頭")

    opened.column.mouseDragged(with: try mouse(.leftMouseDragged, opened, row: 4))
    XCTAssertEqual(document.surface.selectedRange, range(of: 4, in: document))
    opened.column.mouseUp(with: try mouse(.leftMouseUp, opened, row: 4))
  }

  /// 自動スクロールのコマを `count` 回、`interval` 秒ごとに進める（テストの窓は画面に出ないので display link は
  /// 回らない。コマの処理を直に呼ぶ）。
  private func frames(
    _ column: LineNumbersView, _ count: Int, every interval: CFTimeInterval = 0.1,
    clock: inout CFTimeInterval
  ) {
    for _ in 0..<count {
      clock += interval
      column.autoscrollFrame(now: clock)
    }
  }

  /// 本文の下の外までドラッグすると、ポインタを止めたままでもコマごとに本文がスクロールし、選択が見えている下端の行まで
  /// 伸び続ける。速さは外れた距離と見えている行数で決まる（VS Code: 1.5 行以内なら max(30, 見えている行数 ×
  /// (1 + 外れた行数)) 行/秒、3 行より外なら max(200, 見えている行数 × (7 + 外れた行数)) 行/秒）。離せば止まる。
  func testDraggingBelowTheBodyKeepsScrollingWhileThePointerRests() throws {
    let opened = try open(lines(2000))
    let document = opened.document
    let column = opened.column
    let clip = opened.scroll.contentView
    var clock: CFTimeInterval = 0
    column.mouseDown(with: try mouse(.leftMouseDown, opened, row: 2))
    let visibleRows = column.bounds.height / style.lineHeight
    let below = visibleRows + 1
    column.mouseDragged(with: try mouse(.leftMouseDragged, opened, row: below))
    XCTAssertTrue(column.isAutoscrolling)
    frames(column, 1, clock: &clock)
    XCTAssertEqual(clip.bounds.minY, 0, "最初のコマは時刻を取るだけ")

    frames(column, 1, clock: &clock)
    let speed = max(30, visibleRows * (1 + 0.5))
    XCTAssertEqual(clip.bounds.minY, speed * 0.1 * style.lineHeight, accuracy: 0.5)
    func selectedLastRow() -> Int {
      document.lineIndex.point(at: NSMaxRange(document.surface.selectedRange) - 1).row
    }
    let bottomRow = Int((clip.bounds.maxY - 0.5) / style.lineHeight)
    XCTAssertEqual(selectedLastRow(), bottomRow, "見えている下端の行まで伸びる")

    let scrolled = clip.bounds.minY
    frames(column, 2, clock: &clock)
    XCTAssertEqual(clip.bounds.minY, scrolled + 2 * speed * 0.1 * style.lineHeight, accuracy: 0.5)
    XCTAssertGreaterThan(selectedLastRow(), bottomRow, "ポインタが止まっていても伸び続ける")

    let far: CGFloat = 5
    column.mouseDragged(
      with: try mouse(
        .leftMouseDragged, opened, row: column.bounds.maxY / style.lineHeight + far + 0.5))
    let near = clip.bounds.minY
    frames(column, 1, clock: &clock)
    XCTAssertEqual(
      clip.bounds.minY, near + max(200, visibleRows * (7 + far)) * 0.1 * style.lineHeight,
      accuracy: 0.5, "遠くへ外すほど速い")

    column.mouseUp(with: try mouse(.leftMouseUp, opened, row: below))
    XCTAssertFalse(column.isAutoscrolling, "離せば止まる")
    let stopped = clip.bounds.minY
    frames(column, 1, clock: &clock)
    XCTAssertEqual(clip.bounds.minY, stopped, "離した後のコマは何もしない")
  }

  /// 外へ出た後に本文の中へ戻れば自動スクロールは止まり、ポインタの行まで伸ばす。
  func testReturningInsideStopsTheAutoscroll() throws {
    let opened = try open(lines(2000))
    let document = opened.document
    let column = opened.column
    column.mouseDown(with: try mouse(.leftMouseDown, opened, row: 2))
    column.mouseDragged(
      with: try mouse(.leftMouseDragged, opened, row: column.bounds.height / style.lineHeight + 1))
    XCTAssertTrue(column.isAutoscrolling)
    column.mouseDragged(with: try mouse(.leftMouseDragged, opened, row: 5))
    XCTAssertFalse(column.isAutoscrolling, "中へ戻れば止まる")
    XCTAssertEqual(
      document.surface.selectedRange,
      NSUnionRange(range(of: 2, in: document), range(of: 5, in: document)))
    column.mouseUp(with: try mouse(.leftMouseUp, opened, row: 5))
  }

  /// 外へ出したまま面が窓から外れる（文書の切り替え）と、mouse-up は届かないので、外れたところで自動スクロールと選択の
  /// 操作を終える——隠れた文書のスクロールと選択を書き換え続けない。
  func testLeavingTheWindowStopsTheAutoscroll() throws {
    let opened = try open(lines(2000))
    let document = opened.document
    let column = opened.column
    let clip = opened.scroll.contentView
    var clock: CFTimeInterval = 0
    column.mouseDown(with: try mouse(.leftMouseDown, opened, row: 2))
    column.mouseDragged(
      with: try mouse(.leftMouseDragged, opened, row: column.bounds.height / style.lineHeight + 1))
    frames(column, 2, clock: &clock)
    let selection = document.surface.selectedRange
    let scrolled = clip.bounds.minY
    document.surface.view.removeFromSuperview()
    XCTAssertFalse(column.isAutoscrolling, "窓から外れれば止まる")
    frames(column, 2, clock: &clock)
    XCTAssertEqual(clip.bounds.minY, scrolled)
    XCTAssertEqual(document.surface.selectedRange, selection)
  }

  /// 自動スクロールはスクロールできる範囲で止まる——短い文書で下へ出したまま進めても最終行を最上段より先へ送らず、先頭で
  /// 上へ出しても上端より上へ行かない。止まった後も見えている端の行まで選ぶ。
  func testAutoscrollStopsAtTheEndsOfTheScrollableRange() throws {
    let opened = try open(lines(30))
    let document = opened.document
    let column = opened.column
    let clip = try XCTUnwrap(opened.scroll.contentView as? OverscrollClipView)
    var clock: CFTimeInterval = 0
    column.mouseDown(with: try mouse(.leftMouseDown, opened, row: 2))
    let below = column.bounds.height / style.lineHeight + 3
    column.mouseDragged(with: try mouse(.leftMouseDragged, opened, row: below))
    frames(column, 10, clock: &clock)
    XCTAssertEqual(clip.bounds.minY, clip.maximumY, accuracy: 0.5, "最終行を最上段まで送って止まる")
    XCTAssertEqual(
      NSMaxRange(document.surface.selectedRange), document.lineIndex.length, "最終行まで選ぶ")
    column.mouseUp(with: try mouse(.leftMouseUp, opened, row: below))

    document.scroll(toFirstLine: 0)
    column.mouseDown(with: try mouse(.leftMouseDown, opened, row: 3))
    column.mouseDragged(with: try mouse(.leftMouseDragged, opened, row: -2))
    frames(column, 10, clock: &clock)
    XCTAssertEqual(clip.bounds.minY, 0, "上端で止まる")
    XCTAssertEqual(document.surface.selectedRange.location, 0, "先頭の行まで選ぶ")
    column.mouseUp(with: try mouse(.leftMouseUp, opened, row: -2))
  }

  /// ⌃クリックは行を選ばず、焦点も動かさない（VS Code も mac の ⌃クリックを扱わない）。
  func testControlClickSelectsNothing() throws {
    let opened = try open(lines(20))
    let document = opened.document
    document.surface.selectedRange = NSRange(location: 1, length: 0)
    try click(opened, row: 3, .control)
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 1, length: 0))
    XCTAssertFalse(opened.window.firstResponder === document.surface.responder, "焦点は動かない")
  }

  /// ⇧クリックは今の選択の起点（動かない側の端）から押した行まで伸ばす。列で選んだ直後なら、その行が起点。
  func testShiftClickExtendsFromTheSelectionAnchor() throws {
    let opened = try open(lines(20))
    let document = opened.document
    let caret = range(of: 3, in: document).location + 2
    document.surface.selectedRange = NSRange(location: caret, length: 0)
    try click(opened, row: 6, .shift)
    XCTAssertEqual(
      document.surface.selectedRange,
      NSRange(location: caret, length: NSMaxRange(range(of: 6, in: document)) - caret))

    try click(opened, row: 8)
    try click(opened, row: 5, .shift)
    XCTAssertEqual(
      document.surface.selectedRange,
      NSUnionRange(range(of: 5, in: document), range(of: 8, in: document)), "起点は選んだ 8 行目")
  }

  /// 印の列（番号の右）を押しても行は選ばない。
  func testPressingTheMarkColumnSelectsNothing() throws {
    let opened = try open(lines(20))
    let document = opened.document
    document.surface.selectedRange = NSRange(location: 1, length: 0)
    let markX = opened.column.bounds.width - style.marks.gutterWidth / 2
    opened.column.mouseDown(with: try mouse(.leftMouseDown, opened, row: 3, x: markX))
    opened.column.mouseUp(with: try mouse(.leftMouseUp, opened, row: 3, x: markX))
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 1, length: 0))
  }

  /// 起点は動かない側の端——列で上へ伸ばした選択（動く側は先頭）なら押した行が、本文で左へ伸ばした選択なら右端が起点で、
  /// 動く側の端（キャレット）からは伸ばさない。
  func testShiftClickExtendsFromTheFixedEndNotTheCaret() throws {
    let opened = try open(lines(20))
    let document = opened.document
    opened.column.mouseDown(with: try mouse(.leftMouseDown, opened, row: 8))
    opened.column.mouseDragged(with: try mouse(.leftMouseDragged, opened, row: 6))
    opened.column.mouseUp(with: try mouse(.leftMouseUp, opened, row: 6))
    try click(opened, row: 10, .shift)
    XCTAssertEqual(
      document.surface.selectedRange,
      NSUnionRange(range(of: 8, in: document), range(of: 10, in: document)), "起点は押した 8 行目")

    let end = range(of: 3, in: document).location + 4
    document.surface.selectedRange = NSRange(location: end, length: 0)
    for _ in 0..<2 {
      document.surface.responder.perform(
        #selector(NSResponder.moveLeftAndModifySelection(_:)), with: nil)
    }
    XCTAssertEqual(document.surface.caretLocation, end - 2, "前提: 動く側は左端")
    try click(opened, row: 5, .shift)
    XCTAssertEqual(
      document.surface.selectedRange,
      NSRange(location: end, length: NSMaxRange(range(of: 5, in: document)) - end), "起点は右端")
  }
}
