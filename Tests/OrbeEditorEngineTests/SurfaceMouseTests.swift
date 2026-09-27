import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 新しい面のマウス——クリックの回数で単位（文字・語・行・全体）が決まり、その後のドラッグと ⇧クリックは単位と起点の範囲を
/// 保って伸びる。行番号の列は行の単位、URL の ⌘クリックは離したときに開く。壊れると、クリックした字とキャレットの位置が
/// 違う、ダブルクリックのドラッグが字の単位で伸びる、遠くへ飛んだ直後のクリックが別の行に当たる、ドラッグで URL が開く。
@MainActor
final class SurfaceMouseTests: EngineTestCase {
  private let sample = "let value = 1\nfoo.bar baz\n  qux\n"

  func testClickCountsChooseTheUnit() throws {
    let opened = try open(sample)
    _ = host(opened)
    try click(opened, row: 1, column: 5)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 19, length: 0))
    try click(opened, row: 1, column: 5, clicks: 2)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 18, length: 3), "語")
    try click(opened, row: 1, column: 5, clicks: 3)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 14, length: 12), "行（改行まで）")
    try click(opened, row: 1, column: 5, clicks: 4)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 32), "全体")
  }

  /// ダブルクリックの後のドラッグと ⇧クリックは語の単位のまま伸び、元の語は選択に残る。
  func testDragAndShiftClickKeepTheWordUnit() throws {
    let opened = try open(sample)
    _ = host(opened)
    try mouse(opened, .leftMouseDown, at: point(opened, row: 1, column: 9), clicks: 2)
    try mouse(opened, .leftMouseDragged, at: point(opened, row: 0, column: 5), clicks: 2)
    XCTAssertEqual(
      opened.surface.selectedRange, NSRange(location: 4, length: 25 - 4), "上へ伸ばすと語の始まりまで")
    XCTAssertEqual(opened.surface.caretLocation, 4)
    try mouse(opened, .leftMouseUp, at: point(opened, row: 0, column: 5), clicks: 2)
    try click(opened, row: 2, column: 3, flags: .shift)
    XCTAssertEqual(
      opened.surface.selectedRange, NSRange(location: 22, length: 31 - 22), "⇧クリックも語の単位で、元の語から")
  }

  /// 最終行より下の空き地を押すとキャレットは末尾へ。遠くへ飛んだ直後でも、ポインタの下の行に当たる。
  func testClicksBelowTheLastLineAndAfterAFarJump() throws {
    let opened = try open(sample)
    _ = host(opened)
    try click(opened, row: 20, column: 2)
    XCTAssertEqual(opened.surface.caretLocation, 32)
    let long = try open((0..<5000).map { "row \($0)" }.joined(separator: "\n"))
    _ = host(long)
    long.document.scroll(toFirstLine: 4000)
    try click(long, row: 0, column: 4)
    XCTAssertEqual(long.document.text.row(containing: long.surface.caretLocation), 4000)
    XCTAssertEqual(long.surface.caretLocation, long.document.text.lineStart(4000) + 4)
  }

  /// 行番号の列を押すと行を改行まで選び、ドラッグは行の単位で伸びる。⇧↓ で伸ばした後の ⇧クリックは元の行から。
  /// git の印の列は何もしない。
  func testGutterSelectsLines() throws {
    let opened = try open(sample)
    _ = host(opened)
    let gutter = { (row: Int) in CGPoint(x: 8, y: self.point(opened, row: row, column: 0).y) }
    try mouse(opened, .leftMouseDown, at: gutter(1))
    try mouse(opened, .leftMouseDragged, at: gutter(2))
    try mouse(opened, .leftMouseUp, at: gutter(2))
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 14, length: 32 - 14))
    try mouse(opened, .leftMouseDown, at: gutter(0))
    try mouse(opened, .leftMouseUp, at: gutter(0))
    opened.surface.perform(.move(.down, extending: true))
    try mouse(opened, .leftMouseDown, at: gutter(2), flags: .shift)
    try mouse(opened, .leftMouseUp, at: gutter(2), flags: .shift)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 32), "元の行（0）から")
    let marks = CGPoint(
      x: opened.surface.config.columnWidth(lineCount: 4) - 3, y: gutter(1).y)
    try mouse(opened, .leftMouseDown, at: marks)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 32), "印の列は何もしない")
  }

  /// ⌘だけのクリックは URL を離したときに開き、動かして離せば開かない（その間は選択も伸びない）。
  func testCommandClickOpensALinkOnRelease() throws {
    let opened = try open("see https://example.com/a now\n")
    _ = host(opened)
    var opens: [URL] = []
    opened.surface.onOpenLink = { opens.append($0) }
    let on = point(opened, row: 0, column: 10)
    try mouse(opened, .leftMouseDown, at: on, flags: .command)
    try mouse(opened, .leftMouseUp, at: on, flags: .command)
    XCTAssertEqual(opens, [URL(string: "https://example.com/a")!])
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 0), "選択は動かない")
    try mouse(opened, .leftMouseDown, at: on, flags: .command)
    try mouse(opened, .leftMouseDragged, at: point(opened, row: 0, column: 20), flags: .command)
    try mouse(opened, .leftMouseUp, at: point(opened, row: 0, column: 20), flags: .command)
    XCTAssertEqual(opens.count, 1, "動かして離せば開かない")
    XCTAssertEqual(opened.surface.selectedRange.length, 0, "その間は選択が伸びない")
    try click(opened, row: 0, column: 10)
    XCTAssertEqual(opens.count, 1, "素のクリックはキャレットを置くだけ")
    XCTAssertEqual(opened.surface.caretLocation, 10)
  }

  /// 右から左の字を含む行でも、押した字の見た目の位置にキャレットが置かれる（ヘブライ語・アラビア語・混在の行）。右から
  /// 左の並びの中では、字の右の縁が字の前。
  func testClicksLandOnRightToLeftCharacters() throws {
    let opened = try open("ab שלום cd\nمرحبا\nאבג 12\n")
    _ = host(opened)
    let config = opened.surface.config
    let column = config.columnWidth(lineCount: opened.document.text.lineCount)
    for (row, offset) in [(0, 4), (0, 6), (1, 2), (2, 1)] {
      let x = caretX(opened, row: row, offset: offset)
      let y = config.topInset + (CGFloat(row) + 0.5) * config.lineHeight
      try mouse(opened, .leftMouseDown, at: CGPoint(x: column + x - 1, y: y))
      try mouse(opened, .leftMouseUp, at: CGPoint(x: column + x - 1, y: y))
      XCTAssertEqual(
        opened.surface.caretLocation, opened.document.text.lineStart(row) + offset,
        "行 \(row) の位置 \(offset) の字の右の縁のすぐ左")
    }
  }

  /// 4 回以上のクリックの全体は、その後のドラッグで縮まない（VS Code と同じ）。
  func testFourClicksSelectAllAndDraggingKeepsIt() throws {
    let opened = try open(sample)
    _ = host(opened)
    try mouse(opened, .leftMouseDown, at: point(opened, row: 1, column: 5), clicks: 4)
    try mouse(opened, .leftMouseDragged, at: point(opened, row: 1, column: 7), clicks: 4)
    try mouse(opened, .leftMouseUp, at: point(opened, row: 1, column: 7), clicks: 4)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 32))
  }

  /// ⌃クリックは何もしない（選択も焦点も動かない。右クリックのメニューは面の外の仕事）。
  func testControlClickDoesNothing() throws {
    let opened = try open(sample)
    _ = host(opened)
    opened.surface.selectedRange = NSRange(location: 2, length: 0)
    try click(opened, row: 1, column: 5, flags: .control)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 2, length: 0))
  }

  private func pointer(_ opened: Opened) throws -> MouseSelection {
    try XCTUnwrap((opened.surface.responder as? MetalTextView)?.pointer)
  }

  /// 自動スクロールのコマを `count` 回、0.1 秒ごとに進める（窓は画面に出ないので display link は回らない）。
  private func frames(_ pointer: MouseSelection, _ count: Int, clock: inout CFTimeInterval) {
    for _ in 0..<count {
      clock += 0.1
      pointer.frame(now: clock)
    }
  }

  private func position(_ opened: Opened) -> SIMD2<Double> {
    opened.surface.scroll.peek(at: 0).position
  }

  /// ドラッグが本文の下へ出ると、ポインタが止まっていても外れた距離と見えている行数で決まる速さ（VS Code: 1.5 行以内なら
  /// max(30, 見えている行数 × (1 + 外れた行数)) 行/秒、3 行より外なら max(200, 見えている行数 × (7 + 外れた行数)) 行/秒）
  /// で自動スクロールし、選択が見えている下端の行の行末まで伸び続ける。本文の上へ戻るか離せば止まる。
  func testDraggingBelowTheTextAutoscrollsAndExtends() throws {
    let opened = try open((0..<500).map { "row \($0)" }.joined(separator: "\n"))
    _ = host(opened, size: CGSize(width: 600, height: 400))
    let config = opened.surface.config
    let pointer = try pointer(opened)
    var clock: CFTimeInterval = 10
    try mouse(opened, .leftMouseDown, at: point(opened, row: 1, column: 1))
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: 200, y: 400 + config.lineHeight))
    XCTAssertTrue(pointer.isAutoscrolling)
    frames(pointer, 2, clock: &clock)
    let visibleRows = (400 - config.topInset) / config.lineHeight
    let near = max(30, visibleRows * 2) * 0.1 * config.lineHeight
    XCTAssertEqual(position(opened).y, Double(near), accuracy: 0.5, "最初のコマは時刻を取るだけ")
    let text = opened.document.text
    let (first, visible) = opened.document.viewportLines
    let bottom = Int((first + visible - 0.01).rounded(.down))
    XCTAssertEqual(
      opened.surface.caretLocation, NSMaxRange(text.contentRange(ofRow: bottom)), "下端の行の行末")
    XCTAssertEqual(opened.surface.selectedRange.location, text.lineStart(1) + 1)
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: 200, y: 400 + 5 * config.lineHeight))
    let before = position(opened).y
    frames(pointer, 1, clock: &clock)
    XCTAssertEqual(
      position(opened).y - before, Double(max(200, visibleRows * 12) * 0.1 * config.lineHeight),
      accuracy: 0.5, "遠くへ外すほど速い")
    try mouse(opened, .leftMouseDragged, at: point(opened, row: 3, column: 1))
    XCTAssertFalse(pointer.isAutoscrolling, "本文の上へ戻れば止まる")
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: 200, y: 400 + config.lineHeight))
    try mouse(opened, .leftMouseUp, at: CGPoint(x: 200, y: 400 + config.lineHeight))
    XCTAssertFalse(pointer.isAutoscrolling, "離せば止まる")
    let stopped = position(opened)
    frames(pointer, 1, clock: &clock)
    XCTAssertEqual(position(opened), stopped, "離した後のコマは何もしない")
  }

  /// 上の外へ出ると上へ送り、見えている上端の行の行頭（ポインタの x に依らず）まで伸びる。スクロールできる範囲の端で止まり、
  /// 文書の先頭まで選ぶ。
  func testDraggingAboveTheTextReachesTheLineStart() throws {
    let opened = try open((0..<500).map { "row \($0) text" }.joined(separator: "\n"))
    _ = host(opened, size: CGSize(width: 600, height: 400))
    opened.document.scroll(toFirstLine: 3)
    let pointer = try pointer(opened)
    var clock: CFTimeInterval = 10
    try mouse(opened, .leftMouseDown, at: point(opened, row: 5, column: 4))
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: 300, y: -20))
    frames(pointer, 10, clock: &clock)
    XCTAssertEqual(position(opened).y, 0, "上端で止まる")
    XCTAssertEqual(opened.surface.selectedRange.location, 0, "先頭の行の行頭まで選ぶ")
    try mouse(opened, .leftMouseUp, at: CGPoint(x: 300, y: -20))
  }

  /// 左右の外（行番号の列の上・面の右の外）へ出ると横に送り、左はポインタの行の行頭、右は行末まで伸びる。
  func testDraggingSidewaysAutoscrollsHorizontally() throws {
    let long = String(repeating: "x", count: 400)
    let opened = try open((0..<20).map { _ in long }.joined(separator: "\n"))
    _ = host(opened, size: CGSize(width: 400, height: 300))
    _ = opened.surface.snapshot()
    pump()
    let pointer = try pointer(opened)
    var clock: CFTimeInterval = 10
    let text = opened.document.text
    try mouse(opened, .leftMouseDown, at: point(opened, row: 2, column: 3))
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: 460, y: point(opened, row: 4, column: 0).y))
    XCTAssertTrue(pointer.isAutoscrolling)
    XCTAssertEqual(opened.surface.caretLocation, NSMaxRange(text.contentRange(ofRow: 4)), "右は行末")
    frames(pointer, 3, clock: &clock)
    let right = position(opened).x
    XCTAssertGreaterThan(right, 0, "右へ送る")
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: 8, y: point(opened, row: 1, column: 0).y))
    XCTAssertEqual(opened.surface.caretLocation, text.lineStart(1), "左は行頭")
    frames(pointer, 2, clock: &clock)
    XCTAssertLessThan(position(opened).x, right, "左へ送る")
    try mouse(opened, .leftMouseUp, at: CGPoint(x: 8, y: point(opened, row: 1, column: 0).y))
  }

  /// 押したまま面が窓から外れると（文書の切り替え）、mouse-up は届かないので、そこで自動スクロールと選択の操作を終える。
  func testLeavingTheWindowStopsTheAutoscroll() throws {
    let opened = try open((0..<500).map { "row \($0)" }.joined(separator: "\n"))
    let window = host(opened, size: CGSize(width: 600, height: 400))
    let pointer = try pointer(opened)
    var clock: CFTimeInterval = 10
    try mouse(opened, .leftMouseDown, at: point(opened, row: 1, column: 1))
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: 200, y: 460))
    frames(pointer, 2, clock: &clock)
    let selection = opened.surface.selectedRange
    let scrolled = position(opened)
    window.contentView = nil
    XCTAssertFalse(pointer.isAutoscrolling, "窓から外れれば止まる")
    frames(pointer, 2, clock: &clock)
    XCTAssertEqual(position(opened), scrolled)
    XCTAssertEqual(opened.surface.selectedRange, selection)
  }
}
