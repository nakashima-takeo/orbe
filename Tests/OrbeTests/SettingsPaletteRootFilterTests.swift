import XCTest

@testable import Orbe

/// 設定パレット root の絞り込み（font サブと同じ filter 基盤の流用）検証。
/// `SettingsPaletteTests` の拡張として helper（`model`/`captureApply`）を共有する。
/// 絞り込み後も操作が「絞り込み後の選択行（visibleRootRows）」へ効くことを固定する（SSOT 差し替えの回帰止め）。
@MainActor
extension SettingsPaletteTests {

  /// root は絞り込み入力欄あり（filter）。クエリ空なら全 14 行（スコープ＋12 設定＋言語）を出す。
  func testRootHasFilterFieldAndShowsAllRowsWhenEmpty() {
    let p = model()
    XCTAssertTrue(p.render.fieldVisible, "root に絞り込み入力欄が出る")
    XCTAssertTrue(p.render.fieldIsFilter, "filter 入力欄＝← を onLeft（行操作）へ回す")
    XCTAssertEqual(p.render.rows.count, 14, "クエリ空なら全行（スコープ＋12 設定＋言語）")
  }

  /// 打鍵で設定行ラベルを増分絞り込み（大小無視・部分一致）。「背景」で背景系 2 行だけ残る。
  func testRootFilterNarrowsToMatchingLabels() {
    let p = model()
    p.render.query = "背景"
    p.render.onQueryChange()
    XCTAssertEqual(p.render.rows.count, 2)
    XCTAssertTrue(p.render.rows.allSatisfy { $0.label.contains("背景") }, "背景の不透明度 / 背景のブラーだけ残る")
  }

  /// クエリを消すと全行へ戻る（絞り込みは非破壊）。
  func testClearingQueryRestoresAllRows() {
    let p = model()
    p.render.query = "背景"
    p.render.onQueryChange()
    XCTAssertEqual(p.render.rows.count, 2)
    p.render.query = ""
    p.render.onQueryChange()
    XCTAssertEqual(p.render.rows.count, 14, "クエリを消すと全行へ戻る")
  }

  /// 絞り込み後、onRight は「絞り込み後の選択行」の stepper へ効く（全行 index 0＝スコープ反転を叩かない）。
  func testFilteredRightArrowActsOnVisibleRow() {
    let p = model(backgroundOpacity: 90)
    let applied = captureApply(p)
    p.render.query = "背景の不透明度"
    p.render.onQueryChange()  // 絞り込み → 背景の不透明度 1 行・selected=0
    _ = p.render.onRight()  // stepper 増（スコープ反転ではない）
    XCTAssertEqual(applied()?.backgroundOpacity, 91)
    XCTAssertTrue(p.render.rows[0].label.contains("91%"))
  }

  /// 絞り込み後、onLeft は「絞り込み後の選択行」の stepper へ効く（全行 index 0＝スコープ反転を叩かない）。
  func testFilteredLeftArrowActsOnVisibleRow() {
    let p = model(backgroundOpacity: 90)
    let applied = captureApply(p)
    p.render.query = "背景の不透明度"
    p.render.onQueryChange()  // 絞り込み → 背景の不透明度 1 行・selected=0
    p.render.onLeft()  // stepper 減（スコープ反転ではない）
    XCTAssertEqual(applied()?.backgroundOpacity, 89)
    XCTAssertTrue(p.render.rows[0].label.contains("89%"))
  }

  /// 絞り込み後、onActivate は絞り込み後の drillIn 行へ潜る（全行 index 0＝スコープ反転を叩かない）。
  func testFilteredActivateDrillsIntoVisibleRow() {
    let p = model()
    p.render.query = "テーマ"
    p.render.onQueryChange()
    XCTAssertEqual(p.render.rows.count, 1)
    p.render.onActivate()
    XCTAssertEqual(p.render.breadcrumb, "‹ テーマ", "絞り込み後の行（テーマ）へ潜る")
  }

  /// 絞り込み中に drillIn して戻ると、クエリが消えて全行へ戻り、潜った設定行（テーマ・全行 index 5）へ
  /// 選択が復元される（絞り込み後の部分集合 index 0 を全行に当てて先頭スコープ行を選ばない）。
  func testFilteredDrillInAndReturnRestoresSameSettingRow() {
    let p = model()
    p.render.query = "テーマ"
    p.render.onQueryChange()  // 絞り込み → テーマ 1 行・selected=0
    p.render.onActivate()  // テーマサブへ潜る
    p.render.onLeft()  // ← で root へ戻る
    XCTAssertEqual(p.render.query, "", "戻ると絞り込みは消える")
    XCTAssertEqual(p.render.rows.count, 14, "全行へ戻る")
    XCTAssertEqual(p.render.selected, 5, "潜ったテーマ行（全行 index 5）へ選択を復元（スコープ行 0 でない）")
    XCTAssertTrue(p.render.rows[5].label.contains("テーマ"))
  }

  /// 一致 0 件は情報行「一致する設定がありません」を 1 つ出し、Enter で何もしない。
  func testRootFilterNoMatchShowsInfoRowAndNoApply() {
    let p = model()
    let applied = captureApply(p)
    p.render.query = "zzz"
    p.render.onQueryChange()
    XCTAssertEqual(p.render.rows.count, 1)
    XCTAssertFalse(p.render.rows[0].enabled, "0 件は選択・実行対象にしない情報行")
    XCTAssertEqual(p.render.rows[0].label, "一致する設定がありません")
    p.render.onActivate()  // 情報行で Enter → 何もしない
    XCTAssertNil(applied())
  }

  /// 絞り込み後の delete は「絞り込み後の選択行」の上書きを解除する（visibleRootRows の SSOT）。
  /// クエリ空/非空でのキー振り分け（delete＝継承解除 or 文字削除）は queryField（SwiftUI）の責務で実機確認。
  func testFilteredDeleteClearsVisibleRowOverride() {
    let p = model(fontSize: 12)
    p.render.selected = 0
    p.render.onActivate()  // workspace スコープへ
    p.render.selected = 1  // フォントサイズ行
    _ = p.render.onRight()  // 13 へ上書き
    var last: (SettingChange, SettingsScope)?
    p.onApply = { last = ($0, $1) }
    p.render.query = "フォントサイズ"
    p.render.onQueryChange()  // 絞り込み → フォントサイズ 1 行・selected=0
    p.render.onDelete()  // 絞り込み後の行の上書きを解除
    XCTAssertEqual(last?.0, SettingChange(id: .fontSize, value: nil))
    XCTAssertEqual(last?.1, .workspace)
    XCTAssertEqual(p.render.rows[0].detail, "（継承）", "解除後は global 継承表示")
  }
}
