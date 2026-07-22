import XCTest

@testable import Orbe

/// 設定パレットの「背景のブラー」toggle 行（root index 3）の検証。
/// `SettingsPaletteTests` の拡張として helper（`model`/`captureApply`）を共有する。
/// カーソルの点滅と対称の直接編集 toggle 行で、←/→/↵ のいずれでも値を反転する（潜らない・chevron 無し）。
@MainActor
extension SettingsPaletteTests {
  /// ブラー行は root index 3 に既定「オフ」を出し、chevron を持たない（toggle）。
  func testBackgroundBlurRowAppearsWithDefault() {
    let p = model(backgroundBlur: false)
    XCTAssertTrue(p.render.rows[3].label.contains("オフ"), "既定オフを表示")
    XCTAssertFalse(p.render.rows[3].chevron, "toggle 行は chevron を持たない")
  }

  /// → で反転（オフ→オン）。applied と行表示が追従する。
  func testBackgroundBlurToggleWithRight() {
    let p = model(backgroundBlur: false)
    let applied = captureApply(p)
    p.render.onDown()  // 不透明度行
    p.render.onDown()  // ブラー行（index 3）
    _ = p.render.onRight()
    XCTAssertEqual(applied()?.backgroundBlur, true)
    XCTAssertTrue(p.render.rows[3].label.contains("オン"))
  }

  /// ← でも反転（stepper と違い減算でなく flip）。
  func testBackgroundBlurToggleWithLeft() {
    let p = model(backgroundBlur: false)
    let applied = captureApply(p)
    p.render.onDown()  // 不透明度行
    p.render.onDown()  // ブラー行
    p.render.onLeft()
    XCTAssertEqual(applied()?.backgroundBlur, true)
    XCTAssertTrue(p.render.rows[3].label.contains("オン"))
  }

  /// Enter でも反転（drillIn と違い潜らず flip）。root のまま。
  func testBackgroundBlurToggleWithEnter() {
    let p = model(backgroundBlur: false)
    let applied = captureApply(p)
    p.render.onDown()  // 不透明度行
    p.render.onDown()  // ブラー行
    p.render.onActivate()
    XCTAssertEqual(applied()?.backgroundBlur, true)
    XCTAssertTrue(p.render.rows[3].label.contains("オン"))
    XCTAssertNil(p.render.breadcrumb, "潜らない（root のまま）")
  }

  /// 反転は毎回適用（端クランプ無し）。オン→オフへ戻る。
  func testBackgroundBlurTogglesBackToOff() {
    let p = model(backgroundBlur: true)
    let applied = captureApply(p)
    p.render.onDown()  // 不透明度行
    p.render.onDown()  // ブラー行
    _ = p.render.onRight()
    XCTAssertEqual(applied()?.backgroundBlur, false)
    XCTAssertTrue(p.render.rows[3].label.contains("オフ"))
  }

  /// ブラーの反転は隣接する不透明度 stepper・点滅 toggle の行表示を壊さない（独立フィールド）。
  func testBackgroundBlurIndependentFromNeighbors() {
    let p = model(
      fontSize: 12, backgroundOpacity: 90, backgroundBlur: false, cursorStyleBlink: false)
    p.render.onDown()  // 不透明度行
    p.render.onDown()  // ブラー行
    _ = p.render.onRight()  // ブラー → オン
    XCTAssertTrue(p.render.rows[3].label.contains("オン"))
    XCTAssertTrue(p.render.rows[2].label.contains("90%"), "不透明度は道連れで変わらない")
    XCTAssertTrue(p.render.rows[4].label.contains("オフ"), "点滅は道連れで変わらない")
  }
}
