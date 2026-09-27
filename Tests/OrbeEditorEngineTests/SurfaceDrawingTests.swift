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
  private func probe(_ opened: Opened, row: Int, column: CGFloat, dy: CGFloat = 1) -> (x: Int, y: Int) {
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

  /// 取引が置いた位置は、その版の材料を読んだコマから使う（スクロールだけが先に動いたコマを出さない）。
  func testPlacedPositionWaitsForTheMaterialRevision() {
    let box = ScrollBox(elastic: false)
    box.updateLimits {
      $0.lineCount = 1000
      $0.lineHeight = 10
      $0.viewport = SIMD2(100, 100)
    }
    box.place(SIMD2(0, 50))
    box.place(SIMD2(0, 300), heldUntil: 7)
    XCTAssertEqual(box.frame(at: 0, material: 6).position.y, 50, "古い材料のコマは前の位置")
    XCTAssertEqual(box.peek(at: 0).position.y, 300, "main は新しい位置を読む")
    XCTAssertEqual(box.frame(at: 0, material: 7).position.y, 300)
    XCTAssertEqual(box.frame(at: 0, material: 6).position.y, 300, "一度追いついたら持たない")
  }
}
