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
    surface.reveal(NSRange(location: target, length: 0), policy: .center)
    XCTAssertEqual(surface.material.revision, before, "並びの途中では箱へ書かない")
    XCTAssertEqual(surface.selectedRange, NSRange(location: target, length: 3))
    let first = opened.surface.viewportLines.first
    XCTAssertEqual(
      first + opened.surface.viewportLines.visible / 2, 300.5, accuracy: 1, "読み取りは今の値")
    RunLoop.main.run(until: Date())
    XCTAssertEqual(surface.material.revision, before + 1, "周の終わりに 1 回だけ書く")
    let material = surface.material.read()
    XCTAssertEqual(material.caret.selections, [NSRange(location: target, length: 3)])
    XCTAssertEqual(
      surface.scroll.frame(at: 0, period: 1.0 / 120, material: material.revision).position.y,
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

  /// 描画スレッドが版 N の材料を引き取ってから位置を読むまでに main が次の版を出しても、コマは版 N に組む位置で描く——
  /// 次の一致へ続けて飛んだとき、新しい選択に古い位置（一致が見えないコマ）も、古い選択に新しい位置も出ない。窓に
  /// 載せない面は描画スレッドが刻まないので、引き取りと位置の読みの間に次の版を出す並びを決定論的に作れる。
  func testAFrameDrawsThePositionPairedWithTheMaterialItTook() throws {
    let opened = try open(rows(500), size: CGSize(width: 400, height: 184))
    let surface = opened.surface
    let text = opened.document.text
    surface.flush()
    let start = surface.scroll.frame(at: 0, period: 1.0 / 120, material: surface.material.revision)
      .position.y
    func jump(to row: Int) -> Double {
      surface.selectedRange = NSRange(location: text.lineStart(row), length: 3)
      surface.reveal(NSRange(location: text.lineStart(row), length: 0), policy: .center)
      let y = surface.scrollState().position.y
      RunLoop.main.run(until: Date())
      return y
    }
    let first = jump(to: 200)
    let taken = surface.material.read()
    XCTAssertEqual(taken.caret.selections.first?.location, text.lineStart(200), "前提: 版 N は 200 行")
    let second = jump(to: 400)
    XCTAssertNotEqual(first, second, "前提: 飛んだ先が違う")
    XCTAssertEqual(
      surface.scroll.frame(at: 0, period: 1.0 / 120, material: taken.revision - 1).position.y,
      start,
      "版 N より前の材料は飛ぶ前の位置")
    XCTAssertEqual(
      surface.scroll.frame(at: 0, period: 1.0 / 120, material: taken.revision).position.y, first,
      "版 N の材料は 200 行を中央に見せる位置")
    XCTAssertEqual(
      surface.scroll.frame(at: 0, period: 1.0 / 120, material: surface.material.revision).position
        .y, second,
      "版 N+1 の材料は 400 行を中央に見せる位置")
  }

  /// 置いてまだ出していない位置は、その後の指の出来事より前のことなので先に出る——指の量は置いた位置に足される。
  func testAPlacedPositionIsFlushedBeforeAFingerEvent() throws {
    let opened = try open(rows(500), size: CGSize(width: 400, height: 184))
    let surface = opened.surface
    surface.flush()
    let lineHeight = Double(surface.config.lineHeight)
    surface.scroll(toFirstLine: 100)
    surface.scroll(
      ScrollInput(timestamp: CACurrentMediaTime(), delta: SIMD2(0, -30), precise: true))
    XCTAssertEqual(surface.scroll.peek(at: CACurrentMediaTime()).position.y, 100 * lineHeight + 30)
    XCTAssertTrue(surface.pending.isEmpty, "指の出来事の処理の終わりに出している")
  }

  /// 見せる区間がもう見えている取引は、位置を置き直さない——端を越えて引っ張っている間に打っても、見せている位置は端へ
  /// 収められない。引っ張る量は、見せている位置が行高との往復で 1ulp ずれるものを選ぶ（置き直せば端へ跳ぶ）。
  func testATransactionShowingAVisibleCaretKeepsTheOverscrolledPosition() throws {
    let opened = try open(rows(50), size: CGSize(width: 400, height: 184))
    let surface = opened.surface
    surface.flush()
    let lineHeight = Double(surface.config.lineHeight)
    let pull = try XCTUnwrap(
      (1...2000).map { Double($0) * 0.37 }.first {
        let shown = -$0 / ScrollPhysics.stiffness
        return shown / lineHeight * lineHeight != shown
      }, "前提: 往復で 1ulp ずれる位置がある")
    let now = CACurrentMediaTime()
    surface.scroll(ScrollInput(timestamp: now, delta: .zero, precise: true, phase: .began))
    surface.scroll(
      ScrollInput(timestamp: now + 0.01, delta: SIMD2(0, pull), precise: true, phase: .changed))
    let pulled = surface.scroll.peek(at: now + 0.01).position.y
    XCTAssertLessThan(pulled, 0, "前提: 先頭より上へ引っ張っている")
    surface.perform(.insert("x"))
    surface.flush()
    XCTAssertEqual(opened.document.text.length, rows(50).utf16.count + 1, "前提: 打った")
    XCTAssertEqual(surface.scroll.peek(at: now + 0.01).position.y, pulled, "引っ張っている位置のまま")
  }
}
