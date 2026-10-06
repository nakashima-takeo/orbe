import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 差し込みの flow（fixture は gallery と同じ `EditorCodeFixtures` の長い文書）。ミニマップを出さない構成の本物のコードに、文書に
/// 無い行（先頭の前・途中・最終行の後）と区画（試しの view。枠で境が見える）を置き、下の行・行番号・git の印が差し込みの
/// 高さだけ下がること、縦に送ると区画が本文と一緒に動き上端の影が区画の上に出ること、横に送ると区画は動かず横スクロール
/// バーが区画の上に出ること、最後まで送ると最終行の後の差し込みが最上段に来ることを撮る。
extension DesignFlowSnapshotTests {
  func testEditorRows() throws {
    let (scene, document) = try longScene()
    defer { scene.cleanup() }
    let surface = try engine(document)
    let lineCount = document.text.lineCount
    let zone = SampleZoneView(
      title: "行 40 · 二分探索",
      message: "rowIndex(containing:) は starts を二分探索する。行頭のオフセットの列は昇順なので、"
        + "境の扱い（行頭ちょうどのオフセット）だけ確かめたい。")
    let removed = { (lines: [String]) in lines.map(InsertedLine.init) }
    let rows = SurfaceRows(insertions: [
      RowInsertion(line: 0, content: .lines(removed(["// removed header"]))),
      RowInsertion(
        line: 6,
        content: .lines(removed(["  private var cache: [Int: Int] = [:]", "  // removed"]))),
      RowInsertion(line: 40, content: .zone(zone)),
      RowInsertion(line: lineCount, content: .lines(removed(["// removed footer"]))),
    ])
    let settle = {
      surface.flush()
      self.settleFades(scene.pane)
    }
    try hostedFlow(
      "editor_rows", scene,
      steps: [
        (
          "inserted",
          {
            surface.setPresentation(SurfacePresentation(showsMinimap: false))
            surface.setRows(rows)
            settle()
          }
        ),
        (
          "scrolled",
          {
            surface.scroll(toFirstLine: 34.5)
            settle()
          }
        ),
        (
          "scrolled_right",
          {
            let viewport = surface.scrollState().limits.viewport.y
            let zoneTop = surface.rows.top(ofBlock: 2)
            surface.scroll(
              toFirstLine: CGFloat((zoneTop - viewport + 30) / Double(surface.config.lineHeight)))
            surface.scroll(toX: 40 * surface.config.cell)
            settle()
          }
        ),
        (
          "end",
          {
            surface.scroll(toX: 0)
            surface.scroll(toFirstLine: .greatestFiniteMagnitude)
            settle()
          }
        ),
      ])
  }
}
