import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 面の強調の地——選択の地の上・字の下に、行の高さいっぱい・角なしで、決まった重ね順で描く。壊れると一致の地が
/// 選択に隠れる・字を覆う・現在の一致が見分けられない・一致が多いときの重ね順が崩れる。
@MainActor
final class SurfaceHighlightTests: EngineTestCase {
  private static let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
  private static let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
  private static let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
  private static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

  /// 種類ごとに見分けられる不透明な色の見え方。
  private var style: TextSurfaceStyle {
    var style = EngineTestCase.style()
    style.highlights = .init(
      findMatch: Self.red, currentFindMatch: Self.green,
      currentFindLine: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5),
      selectionOccurrence: Self.white,
      selectionOccurrenceInactive: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1),
      wordOccurrence: Self.blue)
    return style
  }

  /// 行 `row`・桁 `column` の、行の上端から 1pt 下の点（字に掛からない）。
  private func probe(_ opened: Opened, row: Int, column: CGFloat) -> (CGFloat, CGFloat) {
    let config = opened.surface.config
    return (
      config.columnWidth(lineCount: opened.document.text.lineCount) + column * config.cell,
      config.topInset + CGFloat(row) * config.lineHeight + 1
    )
  }

  func testGroundsAreDrawnOverTheSelectionWithTheCurrentMatchOnTop() throws {
    let opened = try open("abc abc abc\nxyz\n", name: "a.txt", style: style)
    opened.surface.selectedRange = NSRange(location: 0, length: 11)
    opened.surface.setHighlights(
      [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)], for: .findMatch)
    opened.surface.setHighlights([NSRange(location: 8, length: 3)], for: .currentFindMatch)
    let shot = try pixelShot(opened)
    let at = { (row: Int, column: CGFloat) in
      shot.rgb(
        self.probe(opened, row: row, column: column).0,
        self.probe(opened, row: row, column: column).1)
    }
    XCTAssertEqual(at(0, 1.5), [255, 0, 0], "一致の地は選択の地の上")
    XCTAssertEqual(at(0, 9.5), [0, 255, 0], "現在の一致はその上")
    XCTAssertEqual(at(0, 5.5), [29, 30, 161], "一致の外は選択の地に行全体の地（α .5）が重なる")
    let config = opened.surface.config
    let beyond = config.columnWidth(lineCount: 3) + 30 * config.cell
    XCTAssertEqual(shot.rgb(beyond, config.topInset + 1), [0, 0, 128], "現在の一致の行全体（本文の区画の幅）")
    XCTAssertEqual(at(1, 1.5), [0, 0, 0], "他の行には無い")
  }

  /// 長い行を横に送った後も、一致の地は字に付いて動き、見えている窓の中の一致にだけ出る（一致の間には出ない）。
  func testGroundsOnALongLineFollowTheHorizontalScroll() throws {
    let line = String(repeating: "ab" + String(repeating: "x", count: 18), count: 30)
    let opened = try open(line + "\n", name: "a.txt", style: style)
    _ = host(opened)
    opened.surface.setHighlights(
      (0..<30).map { NSRange(location: $0 * 20, length: 2) }, for: .findMatch)
    _ = try pixelShot(opened)
    let config = opened.surface.config
    opened.surface.scroll(toX: 100 * config.cell)
    XCTAssertEqual(opened.surface.scrollPosition.x, 100 * config.cell, "前提: 横へ 100 桁送った")
    let shot = try pixelShot(opened)
    let at = { (column: CGFloat) in
      shot.rgb(
        self.probe(opened, row: 0, column: column - 100).0,
        self.probe(opened, row: 0, column: column - 100).1)
    }
    XCTAssertEqual(at(100.5), [255, 0, 0], "窓の左端の一致")
    XCTAssertEqual(at(121), [255, 0, 0], "窓の中の一致")
    XCTAssertEqual(at(110.5), [0, 0, 0], "一致の間には無い")
    XCTAssertEqual(at(130.5), [0, 0, 0])
    let column = config.columnWidth(lineCount: opened.document.text.lineCount)
    XCTAssertEqual(shot.rgb(column - 2, config.topInset + 1), [0, 0, 0], "行番号の列の下へくぐらない")
  }

  /// 検索の一致が多い（1000 件を超える）ときは、検索の一致が選択文字列の出現と語の出現の下へ回る。焦点が無いとき、選択文字列
  /// の出現は薄い色。
  func testCrowdedFindMatchesGoBelowTheOccurrences() throws {
    let line = String(repeating: "ab ", count: 1200)
    let opened = try open(line + "\n", name: "a.txt", style: style)
    let matches = (0..<1200).map { NSRange(location: $0 * 3, length: 2) }
    opened.surface.setHighlights(matches, for: .findMatch)
    opened.surface.setHighlights([NSRange(location: 3, length: 2)], for: .wordOccurrence)
    opened.surface.setHighlights([NSRange(location: 6, length: 2)], for: .selectionOccurrence)
    let shot = try pixelShot(opened)
    let at = { (column: CGFloat) in
      shot.rgb(
        self.probe(opened, row: 0, column: column).0, self.probe(opened, row: 0, column: column).1)
    }
    XCTAssertEqual(at(0.5), [255, 0, 0])
    XCTAssertEqual(at(3.5), [0, 0, 255], "語の出現が一致の上")
    XCTAssertEqual(at(6.5), [128, 128, 128], "選択文字列の出現も一致の上（焦点が無いので薄い色）")
    opened.surface.setHighlights(Array(matches.prefix(10)), for: .findMatch)
    let few = try pixelShot(opened)
    let (x, y) = probe(opened, row: 0, column: 3.5)
    XCTAssertEqual(few.rgb(x, y), [255, 0, 0], "多くなければ一致が出現の上")
  }

  /// 同じ区間の列を押し直しても材料を書かない。
  func testPushingTheSameRangesAgainDoesNotWrite() throws {
    let opened = try open("abc\n", name: "a.txt")
    opened.surface.setHighlights([NSRange(location: 0, length: 1)], for: .findMatch)
    let revision = opened.surface.drawn.revision
    opened.surface.setHighlights([NSRange(location: 0, length: 1)], for: .findMatch)
    XCTAssertEqual(opened.surface.drawn.revision, revision)
  }
}
