import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 変換中の文字の見た目のうち IME が決めるもの——指定の色と、属性の無い文字列の中の選択。壊れると IME が色で示す変換の
/// 状態（Google 日本語入力の地の色など）が見えない、どの文節を選んでいるかが見えない。
extension SurfaceInputMethodTests {
  /// IME が文節の下線の色や地の色を指定すれば、それで描く。属性の無い文字列でも、中の選択に長さがあればそこを選んでいる
  /// 文節として本文の色の下線を引く。
  func testMarkedTextFollowsTheColorsTheInputMethodChose() throws {
    let opened = try open("\n")
    _ = host(opened, size: CGSize(width: 400, height: 80))
    fakeInputMethod(opened)
    let clauses = NSMutableAttributedString(string: "aaaa")
    clauses.addAttributes(
      [
        .markedClauseSegment: 0, .underlineStyle: NSUnderlineStyle.thick.rawValue,
        .underlineColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
      ], range: NSRange(location: 0, length: 2))
    clauses.addAttributes(
      [
        .markedClauseSegment: 1, .underlineStyle: NSUnderlineStyle.single.rawValue,
        .backgroundColor: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
      ], range: NSRange(location: 2, length: 2))
    replay([.markAttributed(clauses, selected: NSRange(location: 0, length: 2))], on: opened)
    let config = opened.surface.config
    let column = config.columnWidth(lineCount: 2)
    let top = Int((config.topInset * 2).rounded()) + 1
    let underline = Int((config.topInset * 2).rounded() + (config.baseline * 2).rounded() + 3) + 1
    let x = { (offset: Int) in
      Int(
        ((column + opened.surface.editingEnvironment()!.geometry.x(ofColumn: offset, row: 0)) * 2)
          .rounded())
    }
    let image = try XCTUnwrap(opened.surface.snapshot())
    let ink = pixel(image, x: (x(0) + x(2)) / 2, y: underline)
    XCTAssertTrue(ink[0] > 200 && ink[1] < 60 && ink[2] < 60, "指定の下線の色 \(ink)")
    let ground = pixel(image, x: (x(2) + x(4)) / 2, y: top)
    XCTAssertTrue(ground[2] > 200 && ground[0] < 60 && ground[1] < 60, "指定の地の色 \(ground)")

    replay([.mark("aa", selected: NSRange(location: 0, length: 1))], on: opened)
    let plain = try XCTUnwrap(opened.surface.snapshot())
    XCTAssertEqual(
      Array(pixel(plain, x: (x(0) + x(1)) / 2, y: underline).prefix(3)), [204, 204, 204],
      "中の選択を選んでいる文節にする")
    XCTAssertNotEqual(
      Array(pixel(plain, x: (x(1) + x(2)) / 2, y: underline).prefix(3)), [204, 204, 204],
      "選んでいない字には本文の色の下線を引かない")
  }
}
