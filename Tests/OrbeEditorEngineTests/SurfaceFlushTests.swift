import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 面が描画スレッドへ出す道は 1 か所で、きっかけは面自身の入力の処理の終わりと main の runloop の 1 周の終わり。壊れると、
/// 検索の「次へ」で新しい選択に古い位置のコマが出る、打鍵への Orbe の反応が次のコマに遅れる、指のスクロールの直前に
/// 置いた位置が指の量を消す。
@MainActor
final class SurfaceFlushTests: EngineTestCase {
  private func rows(_ count: Int) -> String {
    (0..<count).map { "row \($0)" }.joined(separator: "\n") + "\n"
  }

  /// Orbe から始まる呼び出しの並び（選択を置く・中央に見せる）は、main の 1 周の終わりに 1 回で出る。並びの途中では箱へ
  /// 書かず、main の読み取り（選択・見えている範囲）は並びの途中でも今の値を返す。
  func testCallsFromOrbeInOneTurnAreFlushedOnceAtItsEnd() throws {
    let opened = try open(rows(500), size: CGSize(width: 400, height: 184))
    let surface = opened.surface
    let before = surface.drawn.revision
    let target = opened.document.text.lineStart(300)
    surface.selectedRange = NSRange(location: target, length: 3)
    surface.scrollToCenter(target)
    XCTAssertEqual(surface.material.revision, before, "並びの途中では箱へ書かない")
    XCTAssertEqual(surface.selectedRange, NSRange(location: target, length: 3))
    let first = opened.document.viewportLines.first
    XCTAssertEqual(
      first + opened.document.viewportLines.visible / 2, 300.5, accuracy: 1, "読み取りは今の値")
    RunLoop.main.run(until: Date())
    XCTAssertEqual(surface.material.revision, before + 1, "周の終わりに 1 回だけ書く")
    let material = surface.material.read()
    XCTAssertEqual(material.caret.selections, [NSRange(location: target, length: 3)])
    XCTAssertEqual(
      surface.scroll.frame(at: 0, material: material.revision).position.y,
      Double(first) * Double(surface.config.lineHeight), accuracy: 1e-6, "同じ書き込みで位置も出る")
  }

  /// 面自身の入力（打鍵）への Orbe の反応は、入力の処理の中に同期に入り、処理の終わりに一緒に 1 回で出る。
  func testOrbesReactionToAnInputIsFlushedWithIt() throws {
    let opened = try open("abc\n")
    _ = host(opened)
    let surface = opened.surface
    opened.document.onSelectionChange = {
      surface.setIndentation(Indentation(unit: 2, usesTabs: false))
    }
    let before = surface.drawn.revision
    try key(opened, "x")
    XCTAssertEqual(surface.material.revision, before + 1, "打鍵の処理の終わりに 1 回")
    XCTAssertEqual(surface.material.read().tabColumns, 2, "反応も同じ書き込み")
    XCTAssertEqual(surface.material.read().caret.carets, [1])
  }

  /// 面自身の入力（マウス・メニューのコマンド・サービス・打鍵の外の IME・undo・落とすドラッグ）は、どれも処理の終わりに
  /// 出す——入口を抜けた時点で出していない変化が残らない。
  func testEachInputOfTheSurfaceIsFlushedAtTheEndOfItsHandling() throws {
    let opened = try open("abc def\nghi\n")
    _ = host(opened)
    let surface = opened.surface
    let view = surface.textView
    let board = privatePasteboard(opened)
    fakeInputMethod(opened)
    surface.flush()
    func flushed(_ label: String, _ input: () throws -> Void) rethrows {
      try input()
      XCTAssertTrue(surface.pending.isEmpty, label)
    }
    try flushed("押す") { try mouse(opened, .leftMouseDown, at: point(opened, row: 0, column: 1)) }
    try flushed("ドラッグ") {
      try mouse(opened, .leftMouseDragged, at: point(opened, row: 0, column: 5))
    }
    try flushed("離す") { try mouse(opened, .leftMouseUp, at: point(opened, row: 0, column: 5)) }
    flushed("カット") { view.cut(nil) }
    board.clearContents()
    board.setString("zz", forType: .string)
    flushed("サービスの返し") { _ = view.readSelection(from: board) }
    flushed("変換") { replay([.mark("か")], on: opened) }
    flushed("変換中の undo") { view.undo(nil) }
    flushed("undo") { view.undo(nil) }
    flushed("redo") { view.redo(nil) }
    let drag = FakeDraggingInfo(
      at: view.convert(point(opened, row: 1, column: 1), to: nil), pasteboard: board,
      operations: .copy)
    flushed("落とすドラッグ") { _ = view.draggingUpdated(drag) }
    flushed("外れる") { view.draggingExited(drag) }
  }

  /// 置いてまだ出していない位置は、その後の指の出来事より前のことなので先に出る——指の量は置いた位置に足される。
  func testAPlacedPositionIsFlushedBeforeAFingerEvent() throws {
    let opened = try open(rows(500), size: CGSize(width: 400, height: 184))
    let surface = opened.surface
    surface.flush()
    let lineHeight = Double(surface.config.lineHeight)
    surface.scroll(toTop: opened.document.text.lineStart(100), hiddenFraction: 0)
    surface.scroll(
      ScrollInput(timestamp: CACurrentMediaTime(), delta: SIMD2(0, -30), precise: true))
    XCTAssertEqual(surface.scroll.peek(at: CACurrentMediaTime()).position.y, 100 * lineHeight + 30)
    XCTAssertTrue(surface.pending.isEmpty, "指の出来事の処理の終わりに出している")
  }
}
