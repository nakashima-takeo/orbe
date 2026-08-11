import SwiftUI
import XCTest

@testable import Orbe

/// clean の行が**分類器の出した語を実際に描いているか**を画で確かめる。
///
/// 分類器のテストは「語がどこかの配列に入っている」までしか言えない。View がその配列を読むのを
/// やめれば語は画面から消えるのに、分類器のテストも gallery（書き出すだけで突合しない）も緑のまま
/// 通る——その隙間だけをここが塞ぐ。突合は「同じ行から語を抜いた画と違うか」の 1 点に絞る
/// （ピクセル比較の baseline を持たないので、見た目の変更で壊れない）。
@MainActor
final class DispatchCleanRowRenderTests: SnapshotTestCase {

  private let size = NSSize(width: 640, height: 96)

  /// 溢れた語（`overflowNotes`）が展開サブラインに描かれている。
  func testSublineDrawsTheOverflowNotes() throws {
    let rows = DesignSceneFixtures.dispatchCleanOverflowModel().clean.rows
    let target = try XCTUnwrap(
      rows.first { !$0.overflowNotes.isEmpty && $0.group == .caution && $0.branch != nil },
      "溢れを持つ確認行が fixture に無い")

    let drawn = try render(rows, expanding: target.id)
    let stripped = try render(
      rows.map { $0.id == target.id ? withoutOverflow($0) : $0 }, expanding: target.id)
    let again = try render(
      rows.map { $0.id == target.id ? withoutOverflow($0) : $0 }, expanding: target.id)

    XCTAssertEqual(stripped, again, "前提: 同じ行の描画は決定的（違えば以下の比較が無意味になる）")
    XCTAssertNotEqual(
      drawn, stripped,
      "溢れた語が描かれていない——分類器が受け皿へ入れても、View が読まなければ画面から消える")
  }

  /// 凍結スナップショットを渡してカーソル行を開き、その行だけを描く。
  private func render(_ rows: [CleanRow], expanding rowID: String) throws -> Data {
    let model = DispatchCleanModel()
    model.enter(rows: rows)
    model.toggle(at: rowID)
    let row = try XCTUnwrap(model.rows.first { $0.id == rowID })
    XCTAssertTrue(model.isExpanded(row), "サブラインが開いた行で比べる")
    return try XCTUnwrap(
      renderPNG(DispatchCleanRow(model: model, row: row), size: size, dark: true))
  }

  private func withoutOverflow(_ row: CleanRow) -> CleanRow {
    CleanRow(
      id: row.id, name: row.name, meta: row.meta, branch: row.branch, head: row.head,
      group: row.group, vocabulary: row.vocabulary, chips: row.chips, lossNotes: row.lossNotes,
      overflowNotes: [], deletesBranchImplicitly: row.deletesBranchImplicitly)
  }
}
