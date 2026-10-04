import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// キャレットと選択の地——本文と同じ 1 コマに描く。選択の地は字の下に行の高さいっぱいの矩形で、改行を含む行は行末から
/// 半角 1 字ぶん伸び、焦点が無ければ弱い色。キャレットは焦点がある間だけ 500ms ごとに点滅し、動くたびに表示から始まる。
/// どのコマも操作の前か後の状態だけ——取引が置いたスクロールは、描画スレッドがその版の材料を読むまで使わない。
@MainActor
final class SurfaceDrawingTests: EngineTestCase {
  private let selection = [38, 79, 120]
  private let inactive = [59, 61, 66]

  private func rgb(_ pixel: [Int]) -> [Int] { Array(pixel.prefix(3)) }

  /// 行 `row`・桁 `column`（半角）の、行の上端から 1pt 下の画素（字に掛からない）。
  private func probe(_ opened: Opened, row: Int, column: CGFloat, dy: CGFloat = 1) -> (
    x: Int, y: Int
  ) {
    let config = opened.surface.config
    let x = config.columnWidth(lineCount: opened.document.text.lineCount) + column * config.cell
    let y = config.topInset + CGFloat(row) * config.lineHeight + dy
    return (Int(x * 2), Int(y * 2))
  }

  func testSelectionIsDrawnUnderTheTextAndReachesPastTheNewline() throws {
    let opened = try open("abc def\nxyz\n")
    _ = host(opened, size: CGSize(width: 400, height: 120))
    opened.surface.updateFocus(true)
    opened.surface.selectedRange = NSRange(location: 4, length: 5)
    let image = try XCTUnwrap(opened.surface.snapshot())
    let inside = probe(opened, row: 0, column: 5)
    XCTAssertEqual(rgb(pixel(image, x: inside.x, y: inside.y)), selection)
    let pastNewline = probe(opened, row: 0, column: 7.5)
    XCTAssertEqual(rgb(pixel(image, x: pastNewline.x, y: pastNewline.y)), selection, "改行の分の半角 1 字")
    let beyond = probe(opened, row: 0, column: 8.5)
    XCTAssertEqual(pixel(image, x: beyond.x, y: beyond.y)[3], 0)
    let before = probe(opened, row: 0, column: 3.5)
    XCTAssertEqual(pixel(image, x: before.x, y: before.y)[3], 0)
    let second = probe(opened, row: 1, column: 0.5)
    XCTAssertEqual(rgb(pixel(image, x: second.x, y: second.y)), selection, "次の行の選択した字")
    opened.surface.updateFocus(false)
    let unfocused = try XCTUnwrap(opened.surface.snapshot())
    XCTAssertEqual(rgb(pixel(unfocused, x: inside.x, y: inside.y)), inactive, "焦点が無ければ弱い色")
  }

  func testCaretIsDrawnOnlyWhileFocused() throws {
    let opened = try open("abc def\n")
    _ = host(opened, size: CGSize(width: 400, height: 80))
    opened.surface.selectedRange = NSRange(location: 7, length: 0)
    let at = probe(opened, row: 0, column: 7, dy: opened.surface.config.lineHeight / 2)
    let x = at.x + 1
    opened.surface.updateFocus(true)
    let focused = try XCTUnwrap(opened.surface.snapshot())
    XCTAssertEqual(pixel(focused, x: x, y: at.y), [255, 255, 255, 255], "キャレット（白）")
    opened.surface.updateFocus(false)
    let unfocused = try XCTUnwrap(opened.surface.snapshot())
    XCTAssertEqual(pixel(unfocused, x: x, y: at.y)[3], 0, "焦点が無ければ描かない")
  }

  /// キャレットと選択の地は全カーソルぶん、本文と同じ 1 コマに描く（見えている行のものだけを引く）。
  func testEveryCursorsCaretAndSelectionAreDrawn() throws {
    let opened = try open("abc def\nxyz\nabc def\n")
    _ = host(opened, size: CGSize(width: 400, height: 120))
    opened.surface.inputScope {
      opened.surface.editor.select(
        CursorList(Cursor(7), others: [Cursor(19), .selecting(NSRange(location: 8, length: 2))]),
        reveal: .none)
    }
    opened.surface.updateFocus(true)
    let image = try XCTUnwrap(opened.surface.snapshot())
    let dy = opened.surface.config.lineHeight / 2
    let first = probe(opened, row: 0, column: 7, dy: dy)
    let third = probe(opened, row: 2, column: 7, dy: dy)
    XCTAssertEqual(pixel(image, x: first.x + 1, y: first.y), [255, 255, 255, 255], "主のキャレット")
    XCTAssertEqual(pixel(image, x: third.x + 1, y: third.y), [255, 255, 255, 255], "他のキャレット")
    let middle = probe(opened, row: 1, column: 6, dy: dy)
    XCTAssertEqual(pixel(image, x: middle.x + 1, y: middle.y)[3], 0, "カーソルの無い所には描かない")
    let selected = probe(opened, row: 1, column: 0.5)
    XCTAssertGreaterThan(pixel(image, x: selected.x, y: selected.y)[3], 0, "他のカーソルの選択の地")
  }

  /// 行頭のキャレットはその行の桁 0 に、本文の終わり（最後の空行）のキャレットは最後の行に描く——前の行には描かない。
  func testCaretsAtLineStartsAndTheEndAreDrawnOnTheirOwnRows() throws {
    let opened = try open("abc def\nxyz\nabc def\n")
    _ = host(opened, size: CGSize(width: 400, height: 120))
    opened.surface.inputScope {
      opened.surface.editor.select(CursorList(Cursor(12), others: [Cursor(20)]), reveal: .none)
    }
    opened.surface.updateFocus(true)
    let image = try XCTUnwrap(opened.surface.snapshot())
    let dy = opened.surface.config.lineHeight / 2
    for row in [2, 3] {
      let at = probe(opened, row: row, column: 0, dy: dy)
      XCTAssertEqual(pixel(image, x: at.x + 1, y: at.y), [255, 255, 255, 255], "行 \(row) の桁 0")
    }
    let end = probe(opened, row: 1, column: 3, dy: dy)
    XCTAssertEqual(pixel(image, x: end.x + 1, y: end.y)[3], 0, "前の行の終わりには描かない")
  }

  /// 右から左の字を含む行でも、キャレットは位置の字の見た目の縁に描き、選択の地は見た目の区間ごとに塗る——`ab שלום cd` の
  /// ש ל（位置 3〜5）を選べば、右から左の並びの右側だけが塗られ、左側の ו ם は塗られない。
  func testCaretAndSelectionFollowRightToLeftCharacters() throws {
    let opened = try open("ab שלום cd\nمرحبا\n")
    _ = host(opened, size: CGSize(width: 400, height: 80))
    opened.surface.updateFocus(true)
    let config = opened.surface.config
    let column = config.columnWidth(lineCount: opened.document.text.lineCount)
    let px = { (x: CGFloat) in Int(((column + x) * 2).rounded()) }
    for (row, offset) in [(0, 5), (1, 2)] {
      opened.surface.selectedRange = NSRange(
        location: opened.document.text.lineStart(row) + offset, length: 0)
      let image = try XCTUnwrap(opened.surface.snapshot())
      let y = Int(((config.topInset + (CGFloat(row) + 0.5) * config.lineHeight) * 2).rounded())
      XCTAssertEqual(
        pixel(image, x: px(caretX(opened, row: row, offset: offset)) + 1, y: y),
        [255, 255, 255, 255],
        "行 \(row) の位置 \(offset) のキャレット")
    }
    opened.surface.selectedRange = NSRange(location: 3, length: 2)
    let image = try XCTUnwrap(opened.surface.snapshot())
    let top = Int(((config.topInset + 1) * 2).rounded())
    let selected = (caretX(opened, row: 0, offset: 4) + caretX(opened, row: 0, offset: 5)) / 2
    XCTAssertEqual(rgb(pixel(image, x: px(selected), y: top)), selection, "ל の上")
    let unselected = (caretX(opened, row: 0, offset: 6) + caretX(opened, row: 0, offset: 7)) / 2
    XCTAssertEqual(pixel(image, x: px(unselected), y: top)[3], 0, "ם の上は塗らない")
  }

  /// 点滅は起点から 500ms の偶数区間で表示し、次に切り替わる時刻だけ起きる。焦点が無ければ描かず、起きない。
  func testBlinkPhase() {
    var caret = CaretMaterial(selections: [], carets: [3], epoch: 10, focused: true)
    XCTAssertTrue(caret.caretVisible(at: 10.2))
    XCTAssertFalse(caret.caretVisible(at: 10.7))
    XCTAssertTrue(caret.caretVisible(at: 11.1))
    XCTAssertEqual(caret.nextBlink(after: 10.2) ?? 0, 10.5, accuracy: 1e-9)
    XCTAssertEqual(caret.nextBlink(after: 10.7) ?? 0, 11, accuracy: 1e-9)
    caret.focused = false
    XCTAssertFalse(caret.caretVisible(at: 10.2))
    XCTAssertNil(caret.nextBlink(after: 10.2))
  }

  /// 点滅は動くたびに表示からやり直す——打鍵・移動で点滅の起点が進み、スクロールだけの操作では変わらない。
  func testTheBlinkRestartsOnlyWhenTheCaretMoves() throws {
    let opened = try open((0..<100).map { "row \($0)" }.joined(separator: "\n"))
    _ = host(opened, size: CGSize(width: 400, height: 120))
    opened.surface.updateFocus(true)
    let epoch = { opened.surface.drawn.caret.epoch }
    let focused = epoch()
    opened.surface.perform(.insert("x"))
    let typed = epoch()
    XCTAssertGreaterThan(typed, focused, "打鍵")
    opened.surface.scrollLines(3)
    XCTAssertEqual(epoch(), typed, "スクロールだけでは変わらない")
    opened.surface.perform(.move(.right, extending: false))
    XCTAssertGreaterThan(epoch(), typed, "移動")
  }

  /// 取引が置いた位置は、その版の材料を読んだコマから使う（スクロールだけが先に動いたコマを出さない）。
  func testPlacedPositionWaitsForTheMaterialRevision() {
    let box = ScrollBox()
    box.updateLimits(
      LimitsUpdate(lineCount: 1000, lineHeight: 10, viewport: SIMD2(100, 100), cell: 7))
    box.place(SIMD2(0, 50))
    box.place(SIMD2(0, 300), forMaterial: 7)
    XCTAssertEqual(box.frame(at: 0, material: 6).position.y, 50, "古い材料のコマは前の位置")
    XCTAssertEqual(box.peek(at: 0).position.y, 300, "main は新しい位置を読む")
    XCTAssertEqual(box.frame(at: 0, material: 7).position.y, 300)
    XCTAssertEqual(box.frame(at: 0, material: 6).position.y, 300, "一度追いついたら持たない")
  }

  /// 版を続けて置けば、どの版の材料にもその版に組む位置を返す——版 8 を置いた後でも、版 7 の材料のコマは版 7 で置いた
  /// 位置を描く（最初の版より前の位置ではない）。範囲と位置を同じ版で続けて置けば、その版より前の材料には両方を置く前の
  /// ものを組む。描画スレッドが引き取った版より前の組は手放す。
  func testEachMaterialRevisionTakesThePositionPlacedWithIt() {
    let box = ScrollBox()
    box.updateLimits(
      LimitsUpdate(lineCount: 1000, lineHeight: 10, viewport: SIMD2(100, 100), cell: 7))
    box.place(SIMD2(0, 50))
    box.updateLimits(
      LimitsUpdate(lineCount: 2000, lineHeight: 10, viewport: SIMD2(100, 100), cell: 7),
      forMaterial: 7)
    box.place(SIMD2(0, 300), forMaterial: 7)
    box.place(SIMD2(0, 900), forMaterial: 8)
    XCTAssertEqual(box.frame(at: 0, material: 6).position.y, 50)
    XCTAssertEqual(box.frame(at: 0, material: 6).limits.lineCount, 1000, "置く前の範囲")
    XCTAssertEqual(box.frame(at: 0, material: 7).position.y, 300, "版 8 を置いた後も版 7 の位置")
    XCTAssertEqual(box.frame(at: 0, material: 7).limits.lineCount, 2000)
    XCTAssertEqual(box.frame(at: 0, material: 8).position.y, 900)
    box.place(SIMD2(0, 400), forMaterial: 9)
    box.taken(material: 9)
    XCTAssertEqual(box.frame(at: 0, material: 8).position.y, 400, "引き取った版より前の組は手放す")
  }

  /// 打鍵で組み直すのは変わった行だけ——打鍵はその 1 行、Enter は分かれた 2 行、複数行の字下げは字下げした行で、見えて
  /// いる他の行は前のコマの組版を使う（色の無い文書で、打鍵の後に役割が届いて描き直すコマを挟まない）。
  func testTypingReshapesOnlyTheChangedRows() throws {
    let opened = try open((0..<40).map { "row \($0) text" }.joined(separator: "\n"), name: "a.txt")
    let surface = opened.surface
    surface.viewStateDidChange(size: CGSize(width: 600, height: 400), scale: 2, visible: true)
    let driver = HeadlessDriver()
    driver.start()
    defer { driver.stop() }
    driver.bind(surface.id)
    func settle() {
      let deadline = Date().addingTimeInterval(5)
      repeat {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      } while !driver.isPaused(surface.id) && Date() < deadline
    }
    // 行の数が変わればつまみが現れて消えるまで描き続けるので、組版した行は合計の増分で数える。
    func total() -> Int {
      let id = surface.id
      return RenderThread.shared.performAndWait { $0.slot(id)?.lines.shapedTotal ?? -1 }
    }
    func shaped(by action: () -> Void) -> Int {
      let before = total()
      action()
      surface.flush()
      settle()
      return total() - before
    }
    settle()
    surface.selectedRange = NSRange(location: opened.document.text.lineStart(5) + 3, length: 0)
    surface.flush()
    settle()
    XCTAssertEqual(shaped { surface.perform(.insert("x")) }, 1, "打鍵した行だけ")
    XCTAssertEqual(shaped { surface.perform(.newline(indents: true)) }, 2, "Enter で分かれた 2 行だけ")
    let text = opened.document.text
    surface.selectedRange = NSRange(
      location: text.lineStart(10), length: text.lineStart(12) + 3 - text.lineStart(10))
    surface.flush()
    settle()
    XCTAssertEqual(shaped { surface.perform(.tab) }, 3, "字下げした 3 行だけ")
  }
}
