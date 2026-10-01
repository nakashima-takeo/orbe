import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 面の git の印を画素で見る（pane に載せた面の `EditorLineMarksTests` と同じ観点）。壊れると印の色・位置が違う、続く行の
/// バーが行ごとに途切れる、先頭行の上の削除の三角が切れる、行番号が印の列に入る。
@MainActor
final class MetalLineMarksTests: EngineTestCase {
  private let style = EngineTestCase.style()

  /// 撮った絵（黒地、2x）と、印のバーの x（pt）。
  private struct Shot {
    let bytes: [UInt8]
    let width: Int
    let barX: CGFloat
    let column: CGFloat

    /// (x, y) pt の画素の RGB。
    func rgb(_ x: CGFloat, _ y: CGFloat) -> [Int] {
      let i = (Int(y * 2) * width + Int(x * 2)) * 4
      return [Int(bytes[i + 2]), Int(bytes[i + 1]), Int(bytes[i])]
    }
  }

  private func shoot(_ opened: Opened) throws -> Shot {
    let id = opened.surface.id
    let black = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    opened.surface.flush()
    let image = try XCTUnwrap(
      RenderThread.shared.performAndWait { Transfer(value: $0.snapshot(id, background: black)) }
        .value)
    let lineCount = opened.document.text.lineCount
    let column = opened.surface.config.columnWidth(lineCount: lineCount)
    let barX = column - style.marks.gutterWidth + style.marks.barInset + style.marks.barWidth / 2
    return Shot(
      bytes: GlyphPixelTests.pixels(image), width: image.width, barX: barX, column: column)
  }

  /// 行 `row`（1 始まり）の縦の中央（pt）。
  private func rowMidY(_ row: Int) -> CGFloat {
    style.topInset + CGFloat(row - 1) * style.lineHeight + style.lineHeight / 2
  }

  private func isBlack(_ c: [Int]) -> Bool { c.allSatisfy { $0 < 12 } }
  private func isRed(_ c: [Int]) -> Bool { c[0] > c[1] + 60 && c[0] > c[2] + 60 }
  private func isGreen(_ c: [Int]) -> Bool { c[1] > c[0] + 60 && c[1] > c[2] + 40 }
  private func isBlue(_ c: [Int]) -> Bool { c[2] > c[0] + 60 && c[2] > c[1] + 40 }

  private func mark(_ baseline: String, on opened: Opened) {
    opened.document.baseline = baseline
    XCTAssertTrue(opened.document.waitUntilCaughtUp())
  }

  /// 追加＝緑・変更＝青のバーがその行に、削除の三角がその境に出て、印の無い行の列は地のまま。バーの色は α 込みで地に
  /// 合成される。
  func testMarksShowTheThreeKindsAtTheirLines() throws {
    let opened = try open("a\nB\nc\nd\ne\n", waitForColors: false)
    mark("a\nb\nc\nx\ne\n", on: opened)
    var shot = try shoot(opened)
    XCTAssertTrue(isBlue(shot.rgb(shot.barX, rowMidY(2))))
    XCTAssertTrue(isBlue(shot.rgb(shot.barX, rowMidY(4))))
    XCTAssertTrue(isBlack(shot.rgb(shot.barX, rowMidY(1))), "印の無い行")
    XCTAssertTrue(isBlack(shot.rgb(shot.barX, rowMidY(3))))
    let left = shot.column - style.marks.gutterWidth
    XCTAssertTrue(isBlack(shot.rgb(left + 0.5, rowMidY(2))), "バーの左（余白）は地")
    XCTAssertTrue(isBlack(shot.rgb(left + 6.5, rowMidY(2))), "バーの右も地")
    let bar = shot.rgb(shot.barX, rowMidY(2))
    let expected = [0.3, 0.5, 0.9].map { Int(($0 * 0.85 * 255).rounded()) }
    XCTAssertTrue(
      zip(bar, expected).allSatisfy { abs($0 - $1) <= 2 }, "色は style の色（α 込み）: \(bar)")

    mark("a\nB\nc\nd\n", on: opened)
    shot = try shoot(opened)
    XCTAssertTrue(isGreen(shot.rgb(shot.barX, rowMidY(5))))
    XCTAssertTrue(isBlack(shot.rgb(shot.barX, rowMidY(2))), "baseline が変われば前の印は消える")

    mark("a\nz\nB\nc\nd\ne\n", on: opened)
    shot = try shoot(opened)
    XCTAssertTrue(
      isRed(shot.rgb(left + style.marks.barInset + 2, rowMidY(2) - 9)), "三角は境（2 行目の上端）")
    XCTAssertTrue(isBlack(shot.rgb(shot.barX, rowMidY(2) + 5)), "三角の下は地（バーではない）")
  }

  /// 続く行の印は 1 本のバーになる（行の境に角の丸みが出ない）。
  func testConsecutiveRowsFormOneBar() throws {
    let opened = try open("a\nB\nC\nd\n", waitForColors: false)
    mark("a\nb\nc\nd\n", on: opened)
    let shot = try shoot(opened)
    let barLeft = shot.column - style.marks.gutterWidth + style.marks.barInset
    let boundary = style.topInset + 2 * style.lineHeight
    let inside = shot.rgb(shot.barX, rowMidY(2))
    for y in [boundary - 0.25, boundary + 0.25] {
      let corner = shot.rgb(barLeft + 0.25, y)
      XCTAssertTrue(
        zip(corner, inside).allSatisfy { abs($0 - $1) <= 2 }, "行の境の角も塗られている: \(corner)")
    }
    XCTAssertTrue(isBlack(shot.rgb(shot.barX, rowMidY(4))))
  }

  /// 先頭行の上の削除は、三角を上端から下向きに置く（境の y = 0 に中央合わせすると上半分が切れる）。
  func testADeletionAboveTheFirstLineIsDrawnFromTheTopEdge() throws {
    let opened = try open("a\nb\n", waitForColors: false)
    mark("z\na\nb\n", on: opened)
    let shot = try shoot(opened)
    let tip = shot.column - style.marks.gutterWidth + style.marks.barInset + 2
    XCTAssertTrue(isRed(shot.rgb(tip, style.topInset + 3)))
    XCTAssertTrue(isBlack(shot.rgb(tip, style.topInset + 9)), "三角は一辺 6 で終わり、その下は地")
    XCTAssertTrue(isBlack(shot.rgb(shot.barX, rowMidY(1))), "1 行目にバーは無い")
  }

  /// 行番号は右寄せで、その右の印の列（バー以外）に数字の字は入らない。
  func testLineNumbersStayOutOfTheMarkColumn() throws {
    let text = (1...12).map { "line \($0)\n" }.joined()
    let opened = try open(text, waitForColors: false)
    mark(text.replacingOccurrences(of: "line 12\n", with: "twelve\n"), on: opened)
    let shot = try shoot(opened)
    let y = rowMidY(12)
    XCTAssertTrue(isBlue(shot.rgb(shot.barX, y)))
    let digitsRight = shot.column - style.marks.gutterWidth - style.gutterTrailingInset
    XCTAssertTrue(
      stride(from: digitsRight - 12, to: digitsRight, by: 0.5).contains {
        !isBlack(shot.rgb($0, y))
      }, "行番号は右余白の手前まで")
    let markColumn = shot.column - style.marks.gutterWidth
    for x in stride(from: digitsRight + 1, to: shot.column, by: 0.5)
    where !(markColumn + 1...markColumn + 6).contains(x) {
      XCTAssertTrue(isBlack(shot.rgb(x, y)), "右余白と印の列（バー以外）に数字の字は無い: x=\(x)")
    }
  }
}
