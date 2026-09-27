import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 新しい面のドラッグの自動スクロール——本文の上下左右の外へ出ると、ポインタが止まっていても VS Code の速さの式で送り、
/// 選択が伸び続け、スクロールできる範囲の端・本文へ戻る・離す・窓から外れるで止まる。壊れると、端での送りが速すぎる・
/// 遅すぎる、先頭や末尾まで選べない、隠れた文書のスクロールと選択を書き換え続ける。
extension SurfaceMouseTests {
  func pointer(_ opened: Opened) throws -> MouseSelection {
    try XCTUnwrap((opened.surface.responder as? MetalTextView)?.pointer)
  }

  /// 自動スクロールのコマを `count` 回、0.1 秒ごとに進める（窓は画面に出ないので display link は回らない）。
  func frames(_ pointer: MouseSelection, _ count: Int, clock: inout CFTimeInterval) {
    for _ in 0..<count {
      clock += 0.1
      pointer.frame(now: clock)
    }
  }

  func position(_ opened: Opened) -> SIMD2<Double> {
    opened.surface.scroll.peek(at: 0).position
  }

  /// ドラッグが本文の下へ出ると、ポインタが止まっていても外れた距離と見えている行数で決まる速さ（VS Code: 1.5 行以内なら
  /// max(30, 見えている行数 × (1 + 外れた行数)) 行/秒、3 行より外なら max(200, 見えている行数 × (7 + 外れた行数)) 行/秒）
  /// で自動スクロールし、選択が見えている下端の行のポインタの桁（行より右なら行末）まで伸び続ける。本文の上へ戻るか離せば
  /// 止まる。
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
      opened.surface.caretLocation, NSMaxRange(text.contentRange(ofRow: bottom)),
      "ポインタが行より右なら、下端の行の行末")
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

  /// 上の外へ出ると、下の外と同じ速さの式で上へ送る（1.5 行以内なら max(30, 見えている行数 × (1 + 外れた行数)) 行/秒）。
  func testDraggingAboveTheTextAutoscrollsAtTheSameSpeed() throws {
    let opened = try open((0..<500).map { "row \($0)" }.joined(separator: "\n"))
    _ = host(opened, size: CGSize(width: 600, height: 400))
    opened.document.scroll(toFirstLine: 200)
    let config = opened.surface.config
    let pointer = try pointer(opened)
    var clock: CFTimeInterval = 10
    try mouse(opened, .leftMouseDown, at: point(opened, row: 5, column: 1))
    try mouse(
      opened, .leftMouseDragged, at: CGPoint(x: 200, y: config.topInset - config.lineHeight))
    let start = position(opened).y
    frames(pointer, 2, clock: &clock)
    let visibleRows = (400 - config.topInset) / config.lineHeight
    XCTAssertEqual(
      start - position(opened).y, Double(max(30, visibleRows * 2) * 0.1 * config.lineHeight),
      accuracy: 0.5)
    try mouse(opened, .leftMouseUp, at: CGPoint(x: 200, y: config.topInset - config.lineHeight))
  }

  /// 下の外へ出ると、最終行が見えるまでは見えている下端の行のポインタの桁まで伸び（VS Code の `TopBottomDragScrolling`）、
  /// 最終行が見えればその行末まで伸びる。
  func testDraggingBelowFollowsThePointerColumnUntilTheLastLine() throws {
    let opened = try open(
      (0..<40).map { "row \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n"))
    _ = host(opened, size: CGSize(width: 600, height: 400))
    let config = opened.surface.config
    let pointer = try pointer(opened)
    var clock: CFTimeInterval = 10
    let x = point(opened, row: 0, column: 5).x
    try mouse(opened, .leftMouseDown, at: point(opened, row: 1, column: 1))
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: x, y: 400 + config.lineHeight))
    frames(pointer, 2, clock: &clock)
    let text = opened.document.text
    let (first, visible) = opened.document.viewportLines
    let bottom = Int((first + visible - 0.01).rounded(.down))
    XCTAssertLessThan(bottom, text.lineCount - 1)
    XCTAssertEqual(opened.surface.caretLocation, text.lineStart(bottom) + 5, "下端の行のポインタの桁")
    var lastVisible = false
    for _ in 0..<50 where !lastVisible {
      frames(pointer, 1, clock: &clock)
      let (first, visible) = opened.document.viewportLines
      lastVisible = Int((first + visible - 0.01).rounded(.down)) >= text.lineCount - 1
    }
    XCTAssertTrue(lastVisible)
    XCTAssertEqual(opened.surface.caretLocation, text.length, "最終行が見えればその行末")
    try mouse(opened, .leftMouseUp, at: CGPoint(x: x, y: 400 + config.lineHeight))
  }

  /// 下の外へ出したままでも、スクロールできる範囲の端（最終行が最上段）で止まり、本文の終わりまで選ぶ。
  func testAutoscrollStopsAtTheBottomEndAndSelectsToTheEnd() throws {
    let opened = try open((0..<30).map { "row \($0) text" }.joined(separator: "\n"))
    _ = host(opened, size: CGSize(width: 600, height: 400))
    let config = opened.surface.config
    let pointer = try pointer(opened)
    var clock: CFTimeInterval = 10
    try mouse(opened, .leftMouseDown, at: point(opened, row: 2, column: 4))
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: 200, y: 400 + 4 * config.lineHeight))
    frames(pointer, 20, clock: &clock)
    let (at, limits) = opened.surface.scroll.peek(at: 0)
    XCTAssertEqual(at.y, limits.maximum.y, accuracy: 0.5, "最終行を最上段まで送って止まる")
    XCTAssertEqual(opened.document.viewportLines.first, 29, accuracy: 0.5)
    XCTAssertEqual(NSMaxRange(opened.surface.selectedRange), opened.document.text.length, "終わりまで")
    try mouse(opened, .leftMouseUp, at: CGPoint(x: 200, y: 400 + 4 * config.lineHeight))
  }

  /// 行番号の列から始めたドラッグも、本文の下の外へ出れば自動スクロールし、行の単位のまま見えている下端の行まで伸びる。
  func testGutterDragBelowTheTextAutoscrollsByLines() throws {
    let opened = try open((0..<500).map { "row \($0)" }.joined(separator: "\n"))
    _ = host(opened, size: CGSize(width: 600, height: 400))
    let config = opened.surface.config
    let pointer = try pointer(opened)
    var clock: CFTimeInterval = 10
    try mouse(opened, .leftMouseDown, at: CGPoint(x: 8, y: point(opened, row: 1, column: 0).y))
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: 8, y: 400 + config.lineHeight))
    XCTAssertTrue(pointer.isAutoscrolling)
    frames(pointer, 3, clock: &clock)
    XCTAssertGreaterThan(position(opened).y, 0)
    let text = opened.document.text
    let (first, visible) = opened.document.viewportLines
    let bottom = Int((first + visible - 0.01).rounded(.down))
    XCTAssertEqual(
      opened.surface.selectedRange,
      NSRange(location: text.lineStart(1), length: text.lineStart(bottom + 1) - text.lineStart(1)),
      "押した行の行頭から、下端の行の改行まで")
    try mouse(opened, .leftMouseUp, at: CGPoint(x: 8, y: 400 + config.lineHeight))
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

  /// 左右の外の速さは縦と同じ式を全角 1 字（半角 2 桁）の単位で数え、その半分ずつ送る（1.5 字以内なら max(30, 見えている
  /// 全角の字数 × (1 + 外れた字数)) 字/秒 × 0.5）。左右の端で止まり、本文の上へ戻れば止まってポインタの位置まで選ぶ。
  func testSidewaysAutoscrollSpeedAndEdges() throws {
    let long = String(repeating: "x", count: 400)
    let opened = try open((0..<20).map { _ in long }.joined(separator: "\n"))
    _ = host(opened, size: CGSize(width: 400, height: 300))
    _ = opened.surface.snapshot()
    pump()
    let config = opened.surface.config
    let area = opened.surface.surfaceLayout.text
    let column = area.minX
    let full = 2 * config.cell
    let step = Double(max(30, area.width / full * 2) * 0.1 * full * 0.5)
    let pointer = try pointer(opened)
    var clock: CFTimeInterval = 10
    let y = point(opened, row: 4, column: 0).y
    try mouse(opened, .leftMouseDown, at: point(opened, row: 2, column: 3))
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: area.maxX + full, y: y))
    frames(pointer, 2, clock: &clock)
    XCTAssertEqual(position(opened).x, step, accuracy: 0.5, "右")
    frames(pointer, 400, clock: &clock)
    let maximum = opened.surface.scroll.peek(at: 0).limits.maximum.x
    XCTAssertGreaterThan(maximum, 0)
    XCTAssertEqual(position(opened).x, maximum, accuracy: 0.5, "右の端で止まる")
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: column - full, y: y))
    let right = position(opened).x
    frames(pointer, 1, clock: &clock)
    XCTAssertEqual(right - position(opened).x, step, accuracy: 0.5, "左")
    frames(pointer, 400, clock: &clock)
    XCTAssertEqual(position(opened).x, 0, "左の端で止まる")
    try mouse(opened, .leftMouseDragged, at: point(opened, row: 3, column: 5))
    XCTAssertFalse(pointer.isAutoscrolling, "本文の上へ戻れば止まる")
    XCTAssertEqual(opened.surface.caretLocation, opened.document.text.lineStart(3) + 5)
    try mouse(opened, .leftMouseUp, at: point(opened, row: 3, column: 5))
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
