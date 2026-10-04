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

  /// 文節の下線は未確定の位置に描く（文節の範囲は未確定の先頭から）——行の途中から変換しても、変換の前の字に下線が掛からない。
  func testClauseUnderlinesFollowTheMarkedRange() throws {
    let opened = try open("xy\n")
    _ = host(opened, size: CGSize(width: 400, height: 80))
    fakeInputMethod(opened)
    opened.surface.selectedRange = NSRange(location: 2, length: 0)
    let clauses = NSMutableAttributedString(string: "aa")
    clauses.addAttributes(
      [
        .markedClauseSegment: 0, .underlineStyle: NSUnderlineStyle.thick.rawValue,
        .underlineColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
      ], range: NSRange(location: 0, length: 2))
    replay([.markAttributed(clauses, selected: NSRange(location: 0, length: 2))], on: opened)
    let config = opened.surface.config
    let column = config.columnWidth(lineCount: 2)
    let underline = Int((config.topInset * 2).rounded() + (config.baseline * 2).rounded() + 3) + 1
    let x = { (offset: Int) in
      Int(
        ((column + opened.surface.editingEnvironment()!.geometry.x(ofColumn: offset, row: 0)) * 2)
          .rounded())
    }
    let image = try XCTUnwrap(opened.surface.snapshot())
    let marked = pixel(image, x: (x(2) + x(4)) / 2, y: underline)
    XCTAssertTrue(marked[0] > 200 && marked[1] < 60, "未確定の下に下線 \(marked)")
    let before = pixel(image, x: (x(0) + x(2)) / 2, y: underline)
    XCTAssertFalse(before[0] > 200 && before[1] < 60, "変換の前の字には掛からない \(before)")
  }

  /// IME が指定した色も、他の色と同じく面の描く色空間（窓の色空間）に解く。壊れると P3 の窓で、変換中の文節の下線と地が
  /// 指定より鮮やかにずれて描かれる。
  func testTheInputMethodsColorsAreResolvedInTheWindowsColorSpace() throws {
    let opened = try open("\n")
    let window = host(opened, size: CGSize(width: 400, height: 80))
    window.colorSpace = .displayP3
    opened.surface.view.viewDidChangeBackingProperties()
    XCTAssertEqual(opened.surface.drawn.space, CGColorSpace(name: CGColorSpace.displayP3), "前提: P3")
    fakeInputMethod(opened)
    let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    let clauses = NSMutableAttributedString(string: "aa")
    clauses.addAttributes(
      [
        .markedClauseSegment: 0, .underlineStyle: NSUnderlineStyle.thick.rawValue,
        .underlineColor: red, .backgroundColor: blue,
      ], range: NSRange(location: 0, length: 2))
    replay([.markAttributed(clauses, selected: NSRange(location: 0, length: 2))], on: opened)
    let clause = try XCTUnwrap(opened.surface.drawn.caret.marked?.appearance.clauses.first)
    let bytes = { (packed: UInt32?) in [0, 8, 16].map { Int(((packed ?? 0) >> $0) & 0xFF) } }
    let p3 = { (color: NSColor) in
      let converted = color.usingColorSpace(.displayP3)!
      return [converted.redComponent, converted.greenComponent, converted.blueComponent].map {
        Int(($0 * 255).rounded())
      }
    }
    XCTAssertEqual(bytes(clause.underline), p3(red), "下線は窓の色空間の値")
    XCTAssertEqual(bytes(clause.background), p3(blue), "地は窓の色空間の値")
  }
}
