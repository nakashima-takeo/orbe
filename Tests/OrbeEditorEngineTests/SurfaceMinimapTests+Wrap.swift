import AppKit
import OrbeEditorCore
import XCTest
@testable import OrbeEditorEngine

/// 折り返す面のミニマップのチャンクの捨て方。
@MainActor
extension SurfaceMinimapTests {
  /// 折り返す面でも、編集した行の前後で段の位置が変わらなければ、捨てるのは編集した行の段のチャンクだけ。編集した行の段の
  /// 数が変われば、その段から後ろを全部捨てる。
  func testWrappedEditsDropTheFollowingChunksOnlyWhenTheSegmentsMove() throws {
    let opened = try open(rows(400), size: CGSize(width: 800, height: 600))
    let surface = opened.surface
    _ = surface.snapshot()
    surface.flush()
    let id = surface.id
    func layout(firstLineSegments: Int) -> RowLayout {
      var rows = RowLayout(lineHeight: 18)
      let starts = (1..<firstLineSegments).map { Int32($0 * 10) }
      let wrapped = WrappedLine(starts: starts, indent: 0, ends: starts)
      rows.setWraps(
        LineWraps(
          width: 100, tabWidth: 28, version: 0, lines: [wrapped] + Array(repeating: nil, count: 400)
        ))
      return rows
    }
    let drop = { (edits: [RowEdit], rows: RowLayout) -> Set<Int> in
      RenderThread.shared.performAndWait { renderer in
        let cells = renderer.slot(id)!.minimapCells
        cells.receive(edits, rows: rows)
        return cells.cached
      }
    }
    XCTAssertEqual(drop([], layout(firstLineSegments: 2)), [0, 1, 2, 3, 4], "前提: 描いたチャンク")
    XCTAssertEqual(
      drop([RowEdit(rows: 63..<64, inserted: 1, version: 1)], layout(firstLineSegments: 2)),
      [0, 2, 3, 4], "段の位置が変わらない打鍵の行のチャンク")
    XCTAssertEqual(
      drop([RowEdit(rows: 0..<1, inserted: 1, version: 2)], layout(firstLineSegments: 3)), [],
      "段の数が増えれば後ろは全部")
  }

  /// 折り返す面のミニマップは段の縮図——縮図の段の数は本文の段の合計で、縮図の段を帯の外で押すと、その段が見えている高さの
  /// 中央に来る。壊れると、長い行の文書で、押した所と違う所へ本文が飛ぶ。
  func testPressingTheMinimapCentersThePressedSegment() throws {
    let opened = try hosted(rows(30, width: 400))
    let surface = opened.surface
    let segments = (0..<opened.document.text.lineCount).map { surface.rows.segments(ofLine: $0) }
    XCTAssertGreaterThan(segments[0], 1, "前提: 行は折り返す")
    let placement = try XCTUnwrap(surface.placementBox.read())
    XCTAssertEqual(placement.lineCount, segments.reduce(0, +), "縮図の段の数は段の合計")
    let target = segments[..<20].reduce(0, +) + 1
    let area = surface.surfaceLayout.minimap
    let y = (CGFloat(target) - placement.firstLine + 0.5) * MinimapLayout.lineHeight
    XCTAssertFalse(placement.sliderContains(y: y), "前提: 帯の外")
    let press = CGPoint(x: area.midX, y: area.minY + y)
    try mouse(opened, .leftMouseDown, at: press)
    try mouse(opened, .leftMouseUp, at: press)
    let lines = surface.viewportLines
    XCTAssertEqual(lines.first + lines.visible / 2, CGFloat(target), accuracy: 1e-6, "行 20 の 2 段目")
  }
}
