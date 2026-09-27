import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 新しい面のミニマップ——字の形を構文の色で GPU に描き、装飾（選択・検索の一致・語の出現・git の印）を重ね、描いた配置を
/// main へ渡す。字の列はチャンクごとに覚え、変わった行のチャンクだけ捨てる。壊れるとミニマップが空・字が構文の色でない・
/// 滑っている間に字や一致が別の行に出る・一致や出現や git の印や選択がミニマップに出ない・打鍵のたびに全部組み直す・色だけ
/// 変わった行が古い色のまま・押下が描いた配置と違う行を指す。
@MainActor
final class SurfaceMinimapTests: EngineTestCase {
  private func rows(_ count: Int) -> String {
    (0..<count).map { "let value\($0) = \"text\" // note" }.joined(separator: "\n") + "\n"
  }

  /// 装飾の種類ごとに見分けられる不透明な色の見え方（行の地は半分の濃さになる）。
  private var style: TextSurfaceStyle {
    var style = EngineTestCase.style()
    style.overview.minimap.findMatch = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    style.overview.minimap.wordOccurrence = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    style.overview.minimap.selection = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    return style
  }

  /// 撮った絵とミニマップの配置。点はミニマップの行と桁で引く。
  private struct Minimap {
    let shot: PixelShot
    let area: CGRect
    let placement: MinimapLayout

    /// 行 `row`・桁 `column` の字の升（1pt × 2pt）の、いちばん明るい画素。
    func cell(_ row: Int, _ column: Int) -> [Int] {
      let x = area.minX + CGFloat(MinimapLine.gutter) / 2 + CGFloat(column)
      let y = area.minY + placement.y(ofLine: row)
      let pixels = [0, 0.5].flatMap { dx in
        [0, 0.5, 1, 1.5].map { dy in shot.rgb(x + dx, y + dy) }
      }
      return pixels.max { $0.reduce(0, +) < $1.reduce(0, +) } ?? [0, 0, 0]
    }

    /// 行 `row` の右端（字の届かない所。行の地だけが出る）の画素。
    func rowEnd(_ row: Int) -> [Int] {
      shot.rgb(area.maxX - 2, area.minY + placement.y(ofLine: row) + 1)
    }
  }

  private func minimap(_ opened: Opened) throws -> Minimap {
    let shot = try pixelShot(opened)
    return Minimap(
      shot: shot, area: opened.surface.surfaceLayout.minimap,
      placement: try XCTUnwrap(opened.surface.placementBox.read()))
  }

  /// ミニマップの区画に字が描かれ、描いた配置が箱に置かれる。
  func testDrawsTheCharactersAndHandsThePlacementToMain() throws {
    let opened = try open(rows(400), size: CGSize(width: 800, height: 300))
    let shot = try pixelShot(opened)
    let area = opened.surface.surfaceLayout.minimap
    var ink = 0
    for y in stride(from: CGFloat(1), to: 40, by: 0.5) {
      for x in stride(from: area.minX + 4, to: area.minX + 40, by: 0.5) where shot.hasInk(x, y) {
        ink += 1
      }
    }
    XCTAssertGreaterThan(ink, 200, "字の形が描かれている")
    XCTAssertFalse(shot.hasInk(area.minX + 1, 30), "字の左のガター（8 デバイス px）は空")
    let placement = try XCTUnwrap(opened.surface.placementBox.read())
    XCTAssertEqual(placement.lineCount, 401)
    XCTAssertEqual(placement.startLine, 0)
    writePNG(try XCTUnwrap(opened.surface.snapshot()), previewURL("minimap.png"))
  }

  /// 打鍵で組み直すのは変わった行のチャンクだけ。行の数が増減した編集はその後ろのチャンクを全部捨てる。役割だけが変わった
  /// 区間は、その行のチャンクだけを捨てる。
  func testOnlyTheChangedChunksAreRebuilt() throws {
    let opened = try open(rows(400), size: CGSize(width: 800, height: 600))
    let surface = opened.surface
    _ = surface.snapshot()
    let cached = { () -> Set<Int> in
      let id = surface.id
      return RenderThread.shared.performAndWait { $0.slot(id)?.minimapCells.cached ?? [] }
    }
    XCTAssertEqual(cached(), [0, 1, 2, 3, 4], "描いた 300 行の 5 チャンク")
    surface.flush()
    let id = surface.id
    let drop = { (edits: [RowEdit]) -> Set<Int> in
      RenderThread.shared.performAndWait { renderer in
        let cells = renderer.slot(id)!.minimapCells
        cells.receive(edits)
        return cells.cached
      }
    }
    XCTAssertEqual(
      drop([RowEdit(rows: 70..<71, inserted: 1, version: 1)]), [0, 2, 3, 4], "打鍵の行のチャンク")
    XCTAssertEqual(
      drop([RowEdit(rows: 200..<201, inserted: 2, version: 2)]), [0, 2], "行が増えれば後ろは全部")
    XCTAssertEqual(
      drop([RowEdit(rows: 10..<130, inserted: 120, version: 2, rolesOnly: true)]), [],
      "役割の変わった行のチャンク")
  }

  /// 字は役割の色で描く（keyword は keyword の色、記号は本文の色）。
  func testGlyphsTakeTheColorOfTheirRole() throws {
    let opened = try open("struct S {}\n", size: CGSize(width: 800, height: 300))
    XCTAssertFalse(
      opened.document.roles.roles(in: NSRange(location: 0, length: 6)).isEmpty, "前提: 色付け")
    let map = try minimap(opened)
    let keyword = map.cell(0, 1)
    let brace = map.cell(0, 9)
    XCTAssertGreaterThan(keyword[2], keyword[0] + 30, "struct は keyword の青: \(keyword)")
    XCTAssertTrue(brace.contains { $0 >= 12 }, "前提: { の字がある")
    XCTAssertLessThan(abs(brace[2] - brace[0]), 10, "{ は本文の灰色: \(brace)")
  }

  /// 文書がミニマップに収まらず滑っている間も、字と一致の地はその行の段に出る（帯と同じ座標）。行 i は `x` を i % 8 + 1 個
  /// 持つので、字の最後の桁で行を見分ける。
  func testGlyphsAndMatchesStayOnTheirRowsWhileTheMinimapSlides() throws {
    let text = (0..<1000).map {
      [700, 704].contains($0) ? "needle\n" : String(repeating: "x", count: $0 % 8 + 1) + "\n"
    }.joined()
    let opened = try open(text, size: CGSize(width: 800, height: 400), style: style)
    let rope = opened.document.text
    opened.surface.scroll(toFirstLine: 690)
    opened.surface.setHighlights(
      [700, 704].map { NSRange(location: rope.lineStart($0), length: 6) }, for: .findMatch)
    let map = try minimap(opened)
    XCTAssertGreaterThan(map.placement.startLine, 0, "前提: ミニマップが滑っている")
    for row in [map.placement.startLine + 1, 690, 697, 710] {
      XCTAssertTrue(map.cell(row, row % 8).contains { $0 >= 12 }, "行 \(row) の最後の字")
      XCTAssertEqual(map.cell(row, row % 8 + 1), [0, 0, 0], "行 \(row) の字の後ろは空")
    }
    XCTAssertGreaterThan(map.rowEnd(704)[0], 60, "行 704 の一致の行の地: \(map.rowEnd(704))")
    XCTAssertEqual(map.rowEnd(703), [0, 0, 0])
  }

  /// 検索の一致は、範囲と、その行の薄い地で出る。選択のある行には行の地を付けない（VS Code と同じ）。
  func testFindMatchesShowAsRangesOnAGroundOfTheirRows() throws {
    let text = (0..<40).map { [12, 20].contains($0) ? "has needle here\n" : "plain line\n" }
      .joined()
    let opened = try open(text, size: CGSize(width: 800, height: 300), style: style)
    let rope = opened.document.text
    let matches = [12, 20].map { NSRange(location: rope.lineStart($0) + 4, length: 6) }
    opened.surface.setHighlights(matches, for: .findMatch)
    opened.surface.selectedRange = matches[0]
    let map = try minimap(opened)
    let ground = map.rowEnd(20)
    XCTAssertGreaterThan(ground[0], 60, "一致の行の薄い地: \(ground)")
    XCTAssertEqual(map.rowEnd(19), [0, 0, 0], "他の行には無い")
    XCTAssertEqual(map.rowEnd(12), [0, 0, 0], "選択の行には行の地を付けない")
    XCTAssertGreaterThan(map.cell(20, 6)[0], ground[0] + 60, "一致の範囲は行の地より濃い")
  }

  /// 一致が多い（1000 件を超える）と、現在の一致だけが出る。
  func testManyFindMatchesLeaveOnlyTheCurrentMatch() throws {
    let text = String(repeating: "a a a a a a a a a a\n", count: 120)
    let opened = try open(text, size: CGSize(width: 800, height: 300), style: style)
    let rope = opened.document.text
    let matches = (0..<120).flatMap { row in
      (0..<10).map { NSRange(location: rope.lineStart(row) + $0 * 2, length: 1) }
    }
    opened.surface.setHighlights(matches, for: .findMatch)
    opened.surface.setHighlights([matches[50 * 10 + 2]], for: .currentFindMatch)
    let map = try minimap(opened)
    XCTAssertGreaterThan(map.rowEnd(50)[0], 60, "現在の一致の行の地")
    XCTAssertEqual(map.rowEnd(55), [0, 0, 0], "他の一致の行は出ない")
    XCTAssertGreaterThan(map.cell(50, 4)[0], map.cell(50, 8)[0] + 60, "範囲は現在の一致だけ")
  }

  /// 語の出現は、範囲と、その行の薄い地で出る。
  func testWordOccurrencesShowInTheMinimap() throws {
    let text = String(repeating: "plain line\n", count: 20)
    let opened = try open(text, size: CGSize(width: 800, height: 300), style: style)
    let rope = opened.document.text
    opened.surface.setHighlights(
      [NSRange(location: rope.lineStart(7), length: 5)], for: .wordOccurrence)
    let map = try minimap(opened)
    XCTAssertGreaterThan(map.rowEnd(7)[2], 60, "語の出現の行の地: \(map.rowEnd(7))")
    XCTAssertEqual(map.rowEnd(6), [0, 0, 0])
    XCTAssertGreaterThan(map.cell(7, 2)[2], map.rowEnd(7)[2] + 60, "範囲は行の地より濃い")
  }

  /// git の印は左端（x 2 デバイス px・幅 2 デバイス px）に、追加・変更・削除の色で 1 行ぶんの高さに出る。削除はその境の
  /// 上の行に出る。
  func testGitMarksShowAtTheLeftEdge() throws {
    let lines = (1...20).map { "line \($0)\n" }.joined()
    let opened = try open(lines, size: CGSize(width: 800, height: 300), waitForColors: false)
    opened.document.baseline =
      lines
      .replacingOccurrences(of: "line 5\n", with: "line five\n")
      .replacingOccurrences(of: "line 10\n", with: "")
      .replacingOccurrences(of: "line 15\n", with: "line 15\nline gone\n")
    XCTAssertTrue(opened.document.waitUntilCaughtUp())
    let map = try minimap(opened)
    let mark = { (row: Int) in map.shot.rgb(map.area.minX + 1.25, map.placement.y(ofLine: row) + 1)
    }
    XCTAssertGreaterThan(mark(4)[2], mark(4)[0] + 60, "行 5 は変更（青）: \(mark(4))")
    XCTAssertGreaterThan(mark(9)[1], mark(9)[0] + 60, "行 10 は追加（緑）: \(mark(9))")
    XCTAssertGreaterThan(mark(14)[0], mark(14)[1] + 60, "削除はその境の上の行（15 行目、赤）: \(mark(14))")
    XCTAssertEqual(mark(2), [0, 0, 0], "印の無い行")
  }

  /// 行を丸ごと選ぶと（改行まで）、その行に選択の行の地が付く（VS Code は範囲の終わりの行まで数える）。
  func testSelectingAWholeLineGroundsItsRow() throws {
    let text = String(repeating: "plain line\n", count: 20)
    let opened = try open(text, size: CGSize(width: 800, height: 300), style: style)
    let rope = opened.document.text
    opened.surface.selectedRange = NSRange(
      location: rope.lineStart(4), length: rope.lineStart(5) - rope.lineStart(4))
    let map = try minimap(opened)
    XCTAssertGreaterThan(map.rowEnd(4)[1], 60, "行 5 の地: \(map.rowEnd(4))")
    XCTAssertEqual(map.rowEnd(5), [0, 0, 0], "次の行には付かない")
    XCTAssertEqual(map.rowEnd(3), [0, 0, 0])
  }

  /// 複数行の選択は、途中の行を行末（本文の終わり）まで選択の色で塗り、その先は行の薄い地だけ（VS Code
  /// `renderDecorationOnLine`）。終わりの行は選択の終わりまで。
  func testAMultiLineSelectionFillsTheMiddleRowsUpToTheirEnds() throws {
    let text = String(repeating: "plain line\n", count: 40)
    let opened = try open(text, size: CGSize(width: 800, height: 300), style: style)
    let rope = opened.document.text
    let start = rope.lineStart(2) + 2
    let end = rope.lineStart(30) + 3
    opened.surface.selectedRange = NSRange(location: start, length: end - start)
    let map = try minimap(opened)
    let inText = map.cell(3, 3)[1]
    let beyond = map.cell(3, 20)[1]
    XCTAssertGreaterThan(beyond, 60, "途中の行の本文の先は行の薄い地")
    XCTAssertGreaterThan(inText, beyond + 60, "選択の色は行末まで: 本文 \(inText) / その先 \(beyond)")
    XCTAssertGreaterThan(map.cell(30, 1)[1], map.cell(30, 4)[1] + 60, "終わりの行は選択の終わりまで")
  }
}
