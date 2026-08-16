import SwiftUI
import XCTest

@testable import Orbe

/// clean の行が**分類器の出した語を実際に描いているか**を画で確かめる。
///
/// 分類器のテストは「語が到達できる配列に入っている」までしか言えない。View がその配列を読むのを
/// やめれば語は画面から消えるのに、分類器のテストも gallery（書き出すだけで突合しない）も緑のまま
/// 通る——その隙間だけをここが塞ぐ。突合は「同じ行から語を抜いた画と違うか」の 1 点に絞る
/// （ピクセル比較の baseline を持たないので、見た目の変更で壊れない）。
@MainActor
final class DispatchCleanRowRenderTests: SnapshotTestCase {

  private let size = NSSize(width: 640, height: 96)

  /// 損失の内訳（`%@ も消えます`）が展開サブラインに描かれている。
  /// デザイン抽出が「黄ピルの行は必ず内訳を書く」と定める、消してはいけない側。
  func testSublineDrawsTheLossNotes() throws {
    try assertSublineDraws(
      pick: { !$0.lossNotes.isEmpty },
      strip: { $0.with(lossNotes: []) },
      message: "損失の内訳が描かれていない")
  }

  /// 溢れた語（`overflowNotes`）が展開サブラインに描かれている。
  func testSublineDrawsTheOverflowNotes() throws {
    try assertSublineDraws(
      pick: { !$0.overflowNotes.isEmpty },
      strip: { $0.with(overflowNotes: []) },
      message: "溢れた語が描かれていない")
  }

  /// 右クラスタ（`chips`）が描かれている。
  ///
  /// 到達可能性の不変条件は「`chips` は行の状態によらず常に描かれる」を土台に、そこへ載らなかった
  /// 語だけをサブラインの有無で数える。**土台が抜けると不変条件そのものが空論になる**のに、
  /// ここだけテストが支えていなかった。
  func testRowDrawsTheChips() throws {
    try assertSublineDraws(
      pick: { !$0.chips.isEmpty },
      strip: { $0.with(chips: []) },
      message: "右クラスタが描かれていない")
  }

  /// merged PR チップがマージ先（base）まで描いている。base だけが違う 2 枚の画を比べる——
  /// 番号しか描かなくなった日に、この 2 枚は同じ画になって落ちる。
  func testMergedPRChipDrawsTheBaseBranch() throws {
    let chipSize = NSSize(width: 220, height: 24)
    let develop = try XCTUnwrap(
      renderPNG(
        DispatchCleanChip(chip: .mergedPR(123, base: "develop")), size: chipSize, dark: true)
    )
    let main = try XCTUnwrap(
      renderPNG(DispatchCleanChip(chip: .mergedPR(123, base: "main")), size: chipSize, dark: true))
    let mainAgain = try XCTUnwrap(
      renderPNG(DispatchCleanChip(chip: .mergedPR(123, base: "main")), size: chipSize, dark: true))
    XCTAssertEqual(main, mainAgain, "前提: 同じチップの描画は決定的（違えば以下の比較が無意味になる）")
    XCTAssertNotEqual(develop, main, "マージ先が画に出ていない")
  }

  /// **未確定行はチェックボックスを描かない**（行頭が回転グリフに替わる）。
  ///
  /// 比べる 2 枚は `isReady` **だけ**が違う同じ行で、しかもどちらもカーソル外・未チェックにする
  /// ——群・チップ・ハイライト・チェック状態のどれかが混ざると、行頭の分岐を丸ごと消しても画は
  /// 違うままになり、テストが何も守らなくなる。
  func testPendingRowDrawsTheWorkingGlyphInsteadOfACheckbox() throws {
    let ready = try XCTUnwrap(
      DispatchWorktreeClassifier.classify([
        // 確認群にするのは、確定しても自動チェックが灯らない（＝2 枚のチェック状態が揃う）ため。
        DispatchCleanFacts(
          path: "/wt/x", branch: "feat/x", head: "aaa", track: "[gone]", openPR: .none,
          status: GitWorktreeStatusCounts(modified: 0, untracked: 0),
          containment: .unmerged(count: 6), operation: .none)
      ]).first)
    let pending = ready.with(isReady: false)
    XCTAssertTrue(ready.isReady)
    XCTAssertFalse(pending.isReady)

    let readyPNG = try renderOffCursor(ready)
    XCTAssertEqual(readyPNG, try renderOffCursor(ready), "前提: 静止した行の描画は決定的")
    XCTAssertNotEqual(
      try renderOffCursor(pending), readyPNG, "未確定行がチェックボックスのまま描かれている")
  }

  /// カーソルを別の行に預けて、対象行だけを描く（ハイライトの有無を画から外す）。
  private func renderOffCursor(_ row: CleanRow) throws -> Data {
    let anchor = try XCTUnwrap(
      DispatchWorktreeClassifier.classify([
        DispatchCleanFacts(
          path: "/wt/anchor", branch: "feat/anchor", head: "bbb", track: "[gone]", openPR: .none,
          status: GitWorktreeStatusCounts(modified: 0, untracked: 0),
          containment: .patchEquivalent(target: "main"), operation: .none)
      ]).first)
    let model = DispatchCleanModel()
    model.enter(rows: [anchor, row])
    XCTAssertEqual(model.cursorRow?.id, anchor.id, "前提: カーソルは対象行に無い")
    return try XCTUnwrap(
      renderPNG(DispatchCleanRow(model: model, row: row), size: size, dark: true))
  }

  /// 「その語を持つ行の画」と「その語だけ抜いた行の画」が違うことを見る。
  private func assertSublineDraws(
    pick: (CleanRow) -> Bool, strip: (CleanRow) -> CleanRow, message: String
  ) throws {
    let rows = DesignSceneFixtures.dispatchCleanOverflowModel().clean.rows
    let target = try XCTUnwrap(
      rows.first { pick($0) && $0.canExpandSubline }, "対象の語を持つ展開可能な行が fixture に無い")

    let drawn = try render(rows, expanding: target.id)
    let stripped = try render(
      rows.map { $0.id == target.id ? strip($0) : $0 }, expanding: target.id)
    let again = try render(
      rows.map { $0.id == target.id ? strip($0) : $0 }, expanding: target.id)

    XCTAssertEqual(stripped, again, "前提: 同じ行の描画は決定的（違えば以下の比較が無意味になる）")
    XCTAssertNotEqual(
      drawn, stripped, "\(message)——分類器が受け皿へ入れても、View が読まなければ画面から消える")
  }

  /// 分類を渡してカーソル行を開き、その行だけを描く。
  private func render(_ rows: [CleanRow], expanding rowID: String) throws -> Data {
    let model = DispatchCleanModel()
    model.enter(rows: rows)
    model.toggle(at: rowID)
    let row = try XCTUnwrap(model.rows.first { $0.id == rowID })
    XCTAssertTrue(model.isExpanded(row), "サブラインが開いた行で比べる")
    return try XCTUnwrap(
      renderPNG(DispatchCleanRow(model: model, row: row), size: size, dark: true))
  }
}

extension CleanRow {
  /// 語の置き場の 1 つだけを差し替えた行（描画の突合用）。
  fileprivate func with(
    isReady: Bool? = nil,
    chips: [CleanChip]? = nil, lossNotes: [CleanChip]? = nil, overflowNotes: [CleanChip]? = nil
  ) -> CleanRow {
    CleanRow(
      id: id, name: name, meta: meta, branch: branch, head: head, group: group,
      isReady: isReady ?? self.isReady,
      vocabulary: vocabulary, chips: chips ?? self.chips, lossNotes: lossNotes ?? self.lossNotes,
      overflowNotes: overflowNotes ?? self.overflowNotes,
      deletesBranchImplicitly: deletesBranchImplicitly)
  }
}
