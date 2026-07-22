import XCTest

@testable import Orbe

/// 設定パレットの font サブパレット検証（theme と対称）。
/// `SettingsPaletteTests` の拡張として helper（`model`/`captureApply`）を共有する。
/// フォント行は root の末尾（index 7・先頭スコープ行の下）。初期選択（フォントサイズ）から ↓×6 で到達する。
/// 先頭固定行は `fontFamily(nil)` の解除行で、その ↵ が着地する値（global は「既定（<実フォント名>）」、
/// workspace は継承先の global 値）を名乗る。● と初期ハイライトが乗り得る。
@MainActor
extension SettingsPaletteTests {
  /// root からフォント行（index 7）まで ↓ で降りる。
  private func moveToFontRow(_ p: SettingsPaletteModel) {
    for _ in 0..<6 { p.render.onDown() }
  }

  /// font サブの既定行ラベル（既定の実フォント名が読める）。ja ストアで本番と同じ文字列を組む。
  private var defaultFontLabel: String {
    LocalizationStore(language: .ja).format(
      .settingsDefaultFont, SettingsRegistry.defaultFontFamily)
  }

  // MARK: - font: root 表示・絞り込みと Enter 確定

  func testRootShowsCurrentFont() {
    let p = model(fontFamily: "Menlo")
    XCTAssertTrue(p.render.rows[7].label.contains("Menlo"))
  }

  /// 完了条件 4・5: 未設定でも root から既定の実フォント名が読める（「（既定）」で終わらない）。
  func testRootFontDefaultWhenUnset() {
    let p = model()
    XCTAssertTrue(p.render.rows[7].label.contains(SettingsRegistry.defaultFontFamily))
    XCTAssertTrue(p.render.rows[7].label.contains(defaultFontLabel), "font サブの既定行と同じ文字列")
  }

  func testFontFilterAndApply() {
    let p = model(fontNames: ["Menlo", "Monaco", "SF Mono"])
    moveToFontRow(p)
    p.render.onActivate()  // 潜る
    p.render.query = "mona"
    p.render.onQueryChange()
    XCTAssertEqual(p.render.rows.map(\.label), ["  Monaco"])
    let applied = captureApply(p)
    p.render.onActivate()  // Enter で確定
    XCTAssertEqual(applied()?.fontFamily, "Monaco")
    XCTAssertTrue(p.render.rows[7].label.contains("Monaco"), "root へ戻りフォント行が更新される")
  }

  func testFontDrillInWithRightArrowCaseInsensitive() {
    let p = model(fontNames: ["Menlo", "SF Mono"])
    moveToFontRow(p)
    _ = p.render.onRight()  // → で潜る（Enter と同等）
    XCTAssertEqual(p.render.breadcrumb, "‹ フォント")
    p.render.query = "SF"
    p.render.onQueryChange()
    XCTAssertEqual(p.render.rows.map(\.label), ["  SF Mono"], "大小無視で絞り込む")
  }

  func testFontEmptyStateInfoRowAndNoApply() {
    let p = model(fontNames: [])
    moveToFontRow(p)
    p.render.onActivate()  // 潜る（列挙不能）
    XCTAssertEqual(p.render.rows.count, 1)
    XCTAssertFalse(p.render.rows[0].enabled, "列挙不能なら情報行を 1 つ（空状態）")
    let applied = captureApply(p)
    p.render.onActivate()  // 情報行で Enter → 適用しない
    XCTAssertNil(applied())
  }

  func testFontFilterNoMatchShowsInfoRowAndNoApply() {
    let p = model(fontNames: ["Menlo", "Monaco"])
    moveToFontRow(p)
    p.render.onActivate()  // font へ潜る
    p.render.query = "zzz"
    p.render.onQueryChange()
    XCTAssertEqual(p.render.rows.count, 1)
    XCTAssertFalse(p.render.rows[0].enabled, "絞り込み 0 件でも情報行を 1 つ")
    let applied = captureApply(p)
    p.render.onActivate()  // 情報行で Enter → 適用しない
    XCTAssertNil(applied())
  }

  /// 完了条件 4: 未設定で潜ると ● と初期ハイライトが既定行（index 0）に揃って乗り、その行から
  /// 既定の実フォント名が読める。カタログの JetBrainsMono 行には ● を付けない（↵ の着地点＝未設定のまま）。
  func testFontUnsetMarksDefaultRow() {
    let p = model(fontFamily: nil, fontNames: [SettingsRegistry.defaultFontFamily, "Menlo"])
    moveToFontRow(p)
    p.render.onActivate()  // font へ
    XCTAssertEqual(
      p.render.rows.map(\.label),
      ["● " + defaultFontLabel, "  " + SettingsRegistry.defaultFontFamily, "  Menlo"])
    XCTAssertEqual(p.render.selected, 0, "未設定なら既定行が初期ハイライト")
    XCTAssertTrue(
      p.render.rows[0].label.contains(SettingsRegistry.defaultFontFamily), "既定の実フォント名が読める")
  }

  /// 完了条件 1・2・4: 設定済み（Menlo）なら ● と初期ハイライトが Menlo 行に乗る（既定行ではない）。
  func testFontSetMarksNameRow() {
    let p = model(fontFamily: "Menlo", fontNames: ["Menlo", "Monaco"])
    moveToFontRow(p)
    p.render.onActivate()  // font へ
    XCTAssertEqual(p.render.rows.map(\.label), ["  " + defaultFontLabel, "● Menlo", "  Monaco"])
    XCTAssertEqual(p.render.selected, 1, "現在値 Menlo の行が初期ハイライト（先頭の既定行でない）")
    let applied = captureApply(p)
    p.render.onActivate()  // ハイライト行をそのまま確定
    XCTAssertEqual(applied()?.fontFamily, "Menlo", "↵ の着地点はハイライト行＝現在値")
  }

  /// 完了条件 5: 絞り込み中は解除行が消えて offset=0 になる。● は現在値の行に付いたまま 1 行もずれない
  /// （解除行の有無で名前行の index がずれる唯一の演算。offset=1 側は testFontSetMarksNameRow が踏む）。
  func testFontMarkerFollowsCurrentValueWhileFiltering() {
    let p = model(fontFamily: "Menlo", fontNames: ["Menlo", "Monaco"])
    moveToFontRow(p)
    p.render.onActivate()  // font へ
    p.render.query = "o"  // Menlo / Monaco の両方が残る
    p.render.onQueryChange()
    XCTAssertEqual(p.render.rows.map(\.label), ["● Menlo", "  Monaco"], "解除行が消えた分 offset=0")
  }

  /// 現在値が絞り込みで表示行から消えたら「現在値の行」は無い（● をどこにも付けない）。
  func testFontNoMarkerWhenCurrentValueFilteredOut() {
    let p = model(fontFamily: "Menlo", fontNames: ["Menlo", "Monaco"])
    moveToFontRow(p)
    p.render.onActivate()  // font へ
    p.render.query = "mona"
    p.render.onQueryChange()
    XCTAssertEqual(p.render.rows.map(\.label), ["  Monaco"], "現在値が消えたので ● は出ない")
  }

  /// 完了条件 2: workspace スコープの解除行は「その ↵ が着地する値」＝継承先の global 値を名乗る
  /// （global の既定フォント名を出すと、Enter で Menlo に着地するのに JetBrainsMono と読める嘘になる）。
  func testFontResetRowLabelFollowsScopeLandingValue() {
    let p = model(
      fontFamily: "Menlo", fontNames: ["Menlo", "Monaco"], scope: .workspace)
    p.render.selected = 7  // フォント行（workspace スコープは agent 行が無効で ↓ 回数が変わるため直接置く）
    p.render.onActivate()  // font へ（WS 上書き無し＝実効値は global の Menlo）
    XCTAssertEqual(
      p.render.rows.map(\.label), ["  グローバルを継承（Menlo）", "● Menlo", "  Monaco"],
      "解除行は継承先の global 値を出す（既定フォント名ではない）")
    let applied = captureApply(p)
    p.render.selected = 0
    p.render.onActivate()  // 解除行を確定 → global 値 Menlo へ継承で戻る
    XCTAssertNil(applied()?.fontFamily, "上書きを解除（＝ラベルどおり global の Menlo へ着地）")
  }

  /// global も未設定なら、workspace の解除行は既定チェーンの実フォント名へ着地する。
  func testFontResetRowLabelInWorkspaceWithUnsetGlobal() {
    let p = model(fontFamily: nil, fontNames: ["Menlo"], scope: .workspace)
    p.render.selected = 7  // フォント行（同上）
    p.render.onActivate()
    XCTAssertEqual(p.render.rows[0].label, "● グローバルを継承（\(SettingsRegistry.defaultFontFamily)）")
    XCTAssertEqual(p.render.selected, 0, "未設定なら解除行が現在値")
  }

  /// 既定行の確定で fontFamily=nil を適用し、root のフォント表示が既定（実フォント名）へ戻る。
  func testFontDefaultRowAppliesNilAndReturnsToRoot() {
    let p = model(fontFamily: "Menlo", fontNames: ["Menlo", "Monaco"])
    moveToFontRow(p)
    p.render.onActivate()  // font へ（selected=1=現在値 Menlo）
    p.render.onUp()  // 既定行（index 0）へ
    var appliedFamily: String? = "SENTINEL"
    p.onApply = { change, _ in
      var layer = SettingsLayer()
      layer[SettingKeys.fontFamily] = "SENTINEL"
      layer.apply(change)
      appliedFamily = layer[SettingKeys.fontFamily]
    }
    p.render.onActivate()  // 既定行を確定
    XCTAssertNil(appliedFamily, "fontFamily=nil を適用（gui.conf から font-family 行が消える）")
    XCTAssertNil(p.render.breadcrumb, "root へ戻る")
    XCTAssertTrue(p.render.rows[7].label.contains(defaultFontLabel), "フォント表示は既定（実フォント名）へ戻る")
  }

  /// 絞り込み中（入力非空）は既定行を出さない。未設定なら現在値の行も無いので選択は先頭のまま。
  func testFontDefaultRowHiddenWhileFiltering() {
    let p = model(fontNames: ["Menlo", "Monaco"])
    moveToFontRow(p)
    p.render.onActivate()  // font へ
    p.render.query = "menlo"
    p.render.onQueryChange()
    XCTAssertEqual(p.render.rows.map(\.label), ["  Menlo"], "絞り込み中は固定行を出さない")
    XCTAssertEqual(p.render.selected, 0)
  }

  /// font は filter 入力欄なので ← が onLeft に回り root へ戻る。
  func testLeftFromFontReturnsToRoot() {
    let p = model(fontNames: ["Menlo"])
    moveToFontRow(p)
    p.render.onActivate()  // font へ
    XCTAssertEqual(p.render.breadcrumb, "‹ フォント")
    XCTAssertTrue(p.render.fieldIsFilter, "font は filter 入力欄＝← を onLeft へ回す")
    p.render.onLeft()  // ← で root へ
    XCTAssertNil(p.render.breadcrumb)
    XCTAssertTrue(p.render.fieldIsFilter, "root は絞り込み入力欄（filter）を保つ")
    XCTAssertEqual(p.render.query, "", "root へ戻ると絞り込みクエリはクリアされる")
  }

  /// font → root（←）で選択が「フォント」行（index 7）へ復元され、focus を取り戻す。
  func testReturnFromFontRestoresSelectionAndFocus() {
    let p = model(fontNames: ["Menlo"])
    moveToFontRow(p)
    p.render.onActivate()  // font へ潜る
    let tokenInFont = p.render.focusToken
    p.render.onLeft()  // ← で root へ
    XCTAssertEqual(p.render.selected, 7, "潜った「フォント」行へ選択を復元")
    XCTAssertGreaterThan(p.render.focusToken, tokenInFont, "root カードへ focus を取り戻す")
  }

  /// 既定行表示中（query 空）に名前行（index 1）を Enter 適用する index offset 経路を踏み、
  /// 適用後 root の「フォント」行（index 7）へ選択復元することを確認する。
  func testReturnAfterFontApplyRestoresSelection() {
    let p = model(fontNames: ["Menlo"])
    moveToFontRow(p)
    p.render.onActivate()  // font へ（rows: ［既定, Menlo］・未設定なので選択は既定行）
    let applied = captureApply(p)
    p.render.onDown()  // Menlo（index 1, fontDefaultRowVisible で offset=1 になる経路）
    p.render.onActivate()  // Menlo を適用 → root へ
    XCTAssertEqual(applied()?.fontFamily, "Menlo")
    XCTAssertEqual(p.render.selected, 7, "適用後の戻りも「フォント」行へ復元")
  }
}
