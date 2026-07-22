import XCTest

@testable import Orbe

/// 設定パレットの絵文字フォントサブパレット検証（theme と同型の固定 2 行）。
/// `SettingsPaletteTests` の拡張として helper（`model`/`captureApply`）を共有する。
/// 絵文字フォント行は root index 9（フォント行 7・タブタイトルフォント行 8 の隣）。
@MainActor
extension SettingsPaletteTests {

  /// root の絵文字フォント行は実効既定（noto）を表示語彙「Noto（同梱）」で出す。
  func testRootShowsEmojiFontDefault() {
    let p = model()
    XCTAssertTrue(p.render.rows[9].label.contains("絵文字フォント"))
    XCTAssertTrue(p.render.rows[9].label.contains("Noto（同梱）"), "未設定は実効既定 noto を表示")
    XCTAssertTrue(p.render.rows[9].chevron, "drillIn 行")
  }

  /// 潜ると Noto（同梱）/ Apple（システム）の固定 2 行。未設定は noto 行に ● と初期ハイライト。
  func testEmojiFontDrillInShowsTwoRowsWithDefaultMarked() {
    let p = model()
    p.render.selected = 9
    p.render.onActivate()
    XCTAssertEqual(p.render.breadcrumb, "‹ 絵文字フォント")
    XCTAssertEqual(p.render.rows.map(\.label), ["● Noto（同梱）", "  Apple（システム）"])
    XCTAssertEqual(p.render.selected, 0, "実効既定 noto の行が初期ハイライト")
    XCTAssertFalse(p.render.fieldVisible, "入力欄なし（theme 型）")
  }

  /// Apple 行の ↵ で emoji-font=apple の単一代入が届き、root 表示が追従する。
  func testEmojiFontApplyApple() {
    let p = model()
    p.render.selected = 9
    p.render.onActivate()
    let applied = captureApply(p)
    p.render.onDown()  // Apple 行
    p.render.onActivate()
    XCTAssertEqual(applied()?[SettingKeys.emojiFont], .apple)
    XCTAssertNil(p.render.breadcrumb, "root へ戻る")
    XCTAssertEqual(p.render.selected, 9, "潜った絵文字フォント行へ選択を復元")
    XCTAssertTrue(p.render.rows[9].label.contains("Apple（システム）"))
  }

  /// 設定済み（apple）で潜ると ● と初期ハイライトが Apple 行に乗る。
  func testEmojiFontSetMarksAppleRow() {
    var global = SettingsLayer()
    global[SettingKeys.emojiFont] = EmojiFontMode.apple
    let p = SettingsPaletteModel(
      values: ScopedSettingsValues(global: global), fontNames: [], agents: [],
      localization: LocalizationStore(language: .ja))
    p.render.selected = 9
    p.render.onActivate()
    XCTAssertEqual(p.render.rows.map(\.label), ["  Noto（同梱）", "● Apple（システム）"])
    XCTAssertEqual(p.render.selected, 1)
  }

  /// ← で root へ戻る（theme と同じナビ）。
  func testEmojiFontLeftReturnsToRoot() {
    let p = model()
    p.render.selected = 9
    p.render.onActivate()
    p.render.onLeft()
    XCTAssertNil(p.render.breadcrumb)
    XCTAssertEqual(p.render.selected, 9, "潜った行へ選択を復元")
  }
}
