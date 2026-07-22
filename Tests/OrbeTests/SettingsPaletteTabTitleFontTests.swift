import XCTest

@testable import Orbe

/// 設定パレットのタブタイトルフォントサブパレット検証（font サブと同じ filter 基盤・
/// 等幅制限なしの全 family 列挙）。`SettingsPaletteTests` の拡張として helper を共有する。
/// タブタイトルフォント行は root index 8（フォント行 7 の隣）。
@MainActor
extension SettingsPaletteTests {

  private func tabTitleModel(
    tabTitleFontFamily: String? = nil, allFontNames: [String] = ["Helvetica", "Menlo"],
    scope: SettingsScope = .global, override: SettingsLayer = SettingsLayer()
  ) -> SettingsPaletteModel {
    var global = SettingsLayer()
    global[SettingKeys.tabTitleFontFamily] = tabTitleFontFamily
    return SettingsPaletteModel(
      values: ScopedSettingsValues(scope: scope, global: global, override: override),
      fontNames: [], allFontNames: allFontNames, agents: [],
      localization: LocalizationStore(language: .ja))
  }

  /// root のタブタイトルフォント行は未設定で「既定（システム等幅）」を出す。
  func testRootShowsTabTitleFontDefaultWhenUnset() {
    let p = tabTitleModel()
    XCTAssertTrue(p.render.rows[8].label.contains("タブタイトルのフォント"))
    XCTAssertTrue(p.render.rows[8].label.contains("既定（システム等幅）"))
    XCTAssertTrue(p.render.rows[8].chevron, "drillIn 行")
  }

  /// 設定済みなら root に family 名がそのまま出る。
  func testRootShowsTabTitleFontValue() {
    let p = tabTitleModel(tabTitleFontFamily: "Helvetica")
    XCTAssertTrue(p.render.rows[8].label.contains("Helvetica"))
  }

  /// 潜ると解除行＋全 family（等幅制限なし）。未設定は解除行に ● と初期ハイライト。
  func testTabTitleFontDrillInShowsAllFamiliesWithResetRow() {
    let p = tabTitleModel()
    p.render.selected = 8
    p.render.onActivate()
    XCTAssertEqual(p.render.breadcrumb, "‹ タブタイトルのフォント")
    XCTAssertTrue(p.render.fieldIsFilter, "絞り込み入力欄あり（font サブと同基盤）")
    XCTAssertEqual(
      p.render.rows.map(\.label), ["● 既定（システム等幅）", "  Helvetica", "  Menlo"],
      "先頭は解除行（着地値を名乗る）・続いてプロポーショナル込みの全 family")
    XCTAssertEqual(p.render.selected, 0, "未設定なら解除行が初期ハイライト")
  }

  /// 絞り込み → ↵ で任意 family（可変幅含む）が単一代入で届き、root 表示が追従する。
  func testTabTitleFontFilterAndApply() {
    let p = tabTitleModel()
    p.render.selected = 8
    p.render.onActivate()
    p.render.query = "helv"
    p.render.onQueryChange()
    XCTAssertEqual(p.render.rows.map(\.label), ["  Helvetica"], "大小無視で絞り込み・解除行は消える")
    let applied = captureApply(p)
    p.render.onActivate()
    XCTAssertEqual(applied()?[SettingKeys.tabTitleFontFamily], "Helvetica")
    XCTAssertEqual(p.render.selected, 8, "適用後はタブタイトルフォント行へ選択を復元")
    XCTAssertTrue(p.render.rows[8].label.contains("Helvetica"))
  }

  /// 設定済みで潜ると ● と初期ハイライトがその family 行に乗る。
  func testTabTitleFontSetMarksNameRow() {
    let p = tabTitleModel(tabTitleFontFamily: "Menlo")
    p.render.selected = 8
    p.render.onActivate()
    XCTAssertEqual(
      p.render.rows.map(\.label), ["  既定（システム等幅）", "  Helvetica", "● Menlo"])
    XCTAssertEqual(p.render.selected, 2)
  }

  /// 解除行の ↵ で nil 代入（既定のシステム等幅へ戻す）。
  func testTabTitleFontResetRowAppliesNil() {
    let p = tabTitleModel(tabTitleFontFamily: "Menlo")
    p.render.selected = 8
    p.render.onActivate()
    var appliedFamily: String? = "SENTINEL"
    p.onApply = { change, _ in
      var layer = SettingsLayer()
      layer[SettingKeys.tabTitleFontFamily] = "SENTINEL"
      layer.apply(change)
      appliedFamily = layer[SettingKeys.tabTitleFontFamily]
    }
    p.render.selected = 0
    p.render.onActivate()
    XCTAssertNil(appliedFamily, "解除＝nil 代入")
    XCTAssertTrue(p.render.rows[8].label.contains("既定（システム等幅）"), "root 表示は既定へ戻る")
  }

  /// workspace スコープの解除行は「その ↵ が着地する値」＝継承先の global 値を名乗る。
  func testTabTitleFontResetRowLabelFollowsScopeLandingValue() {
    let p = tabTitleModel(tabTitleFontFamily: "Menlo", scope: .workspace)
    p.render.selected = 8
    p.render.onActivate()
    XCTAssertEqual(p.render.rows[0].label, "  グローバルを継承（Menlo）", "継承先の global 値を出す")
  }

  /// 解決不能名（`orb config set` の任意文字列）が保存されていても、表示中リストに無いだけで
  /// パレットは壊れない（● はどこにも出ない・選択は先頭）。
  func testTabTitleFontUnresolvableSavedValueShowsNoMarker() {
    let p = tabTitleModel(tabTitleFontFamily: "存在しないファミリ名")
    p.render.selected = 8
    p.render.onActivate()
    XCTAssertEqual(
      p.render.rows.map(\.label), ["  既定（システム等幅）", "  Helvetica", "  Menlo"],
      "● はどの行にも出ない")
    XCTAssertEqual(p.render.selected, 0)
  }

  /// 列挙不能（全 family 空）は情報行 1 つで Enter は何もしない。
  func testTabTitleFontEmptyStateInfoRow() {
    let p = tabTitleModel(allFontNames: [])
    p.render.selected = 8
    p.render.onActivate()
    XCTAssertEqual(p.render.rows.count, 1)
    XCTAssertFalse(p.render.rows[0].enabled)
    let applied = captureApply(p)
    p.render.onActivate()
    XCTAssertNil(applied())
  }

  /// ← で root へ戻り、潜った行へ選択を復元する。
  func testTabTitleFontLeftReturnsToRoot() {
    let p = tabTitleModel()
    p.render.selected = 8
    p.render.onActivate()
    p.render.onLeft()
    XCTAssertNil(p.render.breadcrumb)
    XCTAssertEqual(p.render.selected, 8, "潜った行へ選択を復元")
  }
}
