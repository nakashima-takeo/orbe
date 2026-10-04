import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 面の行の装備——空白の丸点・⌘ で乗せた URL の下線（規則は Core の純関数）と、タブの表示幅。壊れるとタブが違う幅で
/// 開く・単語間の空白に点が出る・下線が普段から出る・URL からずれる・選択の中で点が消える。
@MainActor
final class SurfaceDecorTests: EngineTestCase {
  private let style = EngineTestCase.style()

  /// 行 `row`（0 始まり）の縦の中央（pt）。
  private func rowMidY(_ row: Int) -> CGFloat {
    style.topInset + CGFloat(row) * style.lineHeight + style.lineHeight / 2
  }

  /// 本文の桁 `column`（半角）の左端の x（pt）。
  private func x(_ opened: Opened, _ column: CGFloat) -> CGFloat {
    opened.surface.config.columnWidth(lineCount: opened.document.text.lineCount)
      + column * opened.surface.config.cell
  }

  /// タブの表示幅は文書が検出した単位（ここではスペースの行から 2 桁）——2 個のタブの後の字は 4 桁目に立つ。
  func testTabWidthFollowsTheIndentUnit() throws {
    let opened = try open("f {\n  a\n\t\tx\n}\n", name: "a.txt")
    let shot = try pixelShot(opened)
    XCTAssertEqual(opened.document.indentation.unit, 2)
    XCTAssertTrue(shot.hasInk(x(opened, 4.5), rowMidY(2)), "2 個のタブの後の字は 4 桁目")
    XCTAssertFalse(shot.hasInk(x(opened, 8.5), rowMidY(2)), "既定の 4 桁のタブなら立つ 8 桁目には無い")
  }

  /// CRLF の文書でも行末の `\r` は行の外——行末の 1 個のスペースに点が出る。
  func testCRLFLinesKeepTrailingSpaceDots() throws {
    let opened = try open("  a \r\n\r\n    b\r\n", name: "a.txt")
    let shot = try pixelShot(opened)
    XCTAssertTrue(shot.hasInk(x(opened, 3.5), rowMidY(0)), "行末の 1 個に点")
  }

  /// 丸点は行頭・行末・2 個以上の連続スペースのセルの中央に出て、単語間の 1 個とタブには出ない。
  func testWhitespaceDotsOnlyAtBoundaries() throws {
    let opened = try open("  a b  c \n\td\n", name: "a.txt")
    let shot = try pixelShot(opened)
    let dot = { (column: CGFloat) in shot.hasInk(self.x(opened, column + 0.5), self.rowMidY(0)) }
    XCTAssertTrue(dot(0) && dot(1), "行頭")
    XCTAssertFalse(dot(3), "単語間の 1 個")
    XCTAssertTrue(dot(5) && dot(6), "2 個の連続")
    XCTAssertTrue(dot(8), "行末")
    XCTAssertFalse(shot.hasInk(x(opened, 2), rowMidY(1)), "タブには無い")
  }

  /// 焦点のある面に載せ、⌘ を押して（`command`）`point` へポインタを動かした——ポインタの出来事の入口と同じ 1 か所を通す。
  private func hover(_ opened: Opened, at point: CGPoint, command: Bool = true) {
    let view = opened.surface.view
    opened.surface.textView.pointer.updatePointer(
      at: view.convert(point, to: nil), flags: command ? .command : [], in: view)
  }

  private func focusedHost(_ text: String, name: String) throws -> Opened {
    let opened = try open(text, name: name)
    _ = host(opened)
    opened.surface.updateFocus(true)
    return opened
  }

  /// 下線の行の y（pt）。
  private func underlineY(_ opened: Opened, row: Int = 0) -> CGFloat {
    let config = opened.surface.config
    return config.topInset + CGFloat(row) * config.lineHeight + config.baseline + 3 + 0.25
  }

  /// URL の下線は ⌘ を押してその URL の上にポインタがあるときだけ、区間の左端から右端まで、基線の 3 下に文字と同じ色で
  /// 引く。末尾の句読点には引かない。普段・⌘ を離す・ポインタが URL の外、では引かない。
  func testLinkUnderlineShowsOnlyUnderTheCommandHoveredURL() throws {
    let opened = try focusedHost("see https://example.com/a. ok\n", name: "a.txt")
    let y = underlineY(opened)
    XCTAssertFalse(try pixelShot(opened).hasInk(x(opened, 10.5), y), "普段は下線が無い")

    hover(opened, at: point(opened, row: 0, column: 10))
    let shot = try pixelShot(opened)
    XCTAssertEqual(shot.rgb(x(opened, 10.5), y), [204, 204, 204], "URL の中は文字の色")
    XCTAssertEqual(shot.rgb(x(opened, 4.5), y), [204, 204, 204], "URL の左端から")
    XCTAssertFalse(shot.hasInk(x(opened, 3.5), y), "URL の前には無い")
    XCTAssertFalse(shot.hasInk(x(opened, 25.5), y), "末尾の句読点には無い")

    hover(opened, at: point(opened, row: 0, column: 10), command: false)
    XCTAssertFalse(try pixelShot(opened).hasInk(x(opened, 10.5), y), "⌘ を離せば消える")
    hover(opened, at: point(opened, row: 0, column: 1))
    XCTAssertFalse(try pixelShot(opened).hasInk(x(opened, 10.5), y), "ポインタが URL の外なら引かない")
  }

  /// 面に焦点が無ければ、⌘ を押して URL の上にいても下線は引かない（指にもならない）。
  func testLinkUnderlineNeedsFocus() throws {
    let opened = try focusedHost("see https://example.com/a ok\n", name: "a.txt")
    opened.surface.updateFocus(false)
    hover(opened, at: point(opened, row: 0, column: 10))
    XCTAssertFalse(try pixelShot(opened).hasInk(x(opened, 10.5), underlineY(opened)))
  }

  /// スクロールで URL がポインタの下から外れれば、下線は消える（ポインタは動いていない）。
  func testLinkUnderlineFollowsThePointerThroughScrolling() throws {
    let opened = try focusedHost(
      "see https://example.com/a ok\n" + String(repeating: "plain\n", count: 80), name: "a.txt")
    hover(opened, at: point(opened, row: 0, column: 10))
    XCTAssertTrue(try pixelShot(opened).hasInk(x(opened, 10.5), underlineY(opened)), "前提: 下線がある")
    opened.surface.scroll(toFirstLine: 1)
    XCTAssertFalse(
      try pixelShot(opened).hasInk(x(opened, 10.5), underlineY(opened)), "ポインタの下は URL の無い行")
  }

  /// コメントの中の URL の下線は、そこの字と同じ comment の役割の色。
  func testLinkUnderlineInACommentTakesTheCommentColor() throws {
    let opened = try focusedHost("// see https://a.b/c now\n", name: "a.swift")
    hover(opened, at: point(opened, row: 0, column: 12))
    let shot = try pixelShot(opened)
    let y = underlineY(opened)
    let comment = [107, 153, 84]
    for column: CGFloat in [7.5, 12.5, 18.5] {
      let ink = shot.rgb(x(opened, column), y)
      XCTAssertTrue(zip(ink, comment).allSatisfy { abs($0 - $1) <= 1 }, "\(column) 桁: \(ink)")
    }
  }

  /// 装備は選択の地の上、字の下に描く——選択した範囲でも点は選択の外と同じに見える。
  func testDecorationsAreDrawnOverTheSelection() throws {
    let opened = try open("    a\n    b\n", name: "a.txt")
    opened.surface.selectedRange = NSRange(location: 0, length: 5)
    let shot = try pixelShot(opened)
    XCTAssertEqual(
      shot.rgb(x(opened, 1.5), rowMidY(0)), shot.rgb(x(opened, 1.5), rowMidY(1)),
      "選択の中の点は選択の外の点と同じ色")
    XCTAssertEqual(shot.rgb(x(opened, 1.05), rowMidY(0)), [59, 61, 66], "点の間は選択の地（焦点が無いので弱い色）")
  }
}
