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
        LineWraps(width: 100, tabWidth: 28, lines: [wrapped] + Array(repeating: nil, count: 400)))
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
      drop([RowEdit(rows: 70..<71, inserted: 1, version: 1)], layout(firstLineSegments: 2)),
      [0, 2, 3, 4], "段の位置が変わらない打鍵の行のチャンク")
    XCTAssertEqual(
      drop([RowEdit(rows: 0..<1, inserted: 1, version: 2)], layout(firstLineSegments: 3)), [],
      "段の数が増えれば後ろは全部")
  }
}
