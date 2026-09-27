import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 新しい面のミニマップ——字の形を構文の色で GPU に描き、装飾を重ね、描いた配置を main へ渡す。字の列はチャンクごとに
/// 覚え、変わった行のチャンクだけ捨てる。壊れるとミニマップが空・字がずれる・打鍵のたびに全部組み直す・色だけ変わった
/// 行が古い色のまま・押下が描いた配置と違う行を指す。
@MainActor
final class SurfaceMinimapTests: EngineTestCase {
  private func rows(_ count: Int) -> String {
    (0..<count).map { "let value\($0) = \"text\" // note" }.joined(separator: "\n") + "\n"
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
}
