import XCTest

@testable import Orbe

/// 設定パレットの「カーソルの点滅」toggle 行（root index 4）の検証。
/// `SettingsPaletteTests` の拡張として helper（`model`/`captureApply`）を共有する。
/// stepper と対称の直接編集行で、←/→/↵ のいずれでも値を反転する（潜らない・chevron 無し）。
@MainActor
extension SettingsPaletteTests {
  /// → で反転（オフ→オン）。applied と行表示が追従する。
  func testCursorBlinkToggleWithRight() {
    let p = model(cursorStyleBlink: false)
    let applied = captureApply(p)
    p.render.onDown()  // 不透明度行
    p.render.onDown()  // ブラー行
    p.render.onDown()  // 点滅行（index 4）
    _ = p.render.onRight()
    XCTAssertEqual(applied()?.cursorStyleBlink, true)
    XCTAssertTrue(p.render.rows[4].label.contains("オン"))
  }

  /// ← でも反転（stepper と違い減算でなく flip）。
  func testCursorBlinkToggleWithLeft() {
    let p = model(cursorStyleBlink: false)
    let applied = captureApply(p)
    p.render.onDown()
    p.render.onDown()  // ブラー行
    p.render.onDown()  // 点滅行
    p.render.onLeft()
    XCTAssertEqual(applied()?.cursorStyleBlink, true)
    XCTAssertTrue(p.render.rows[4].label.contains("オン"))
  }

  /// Enter でも反転（drillIn と違い潜らず flip）。root のまま。
  func testCursorBlinkToggleWithEnter() {
    let p = model(cursorStyleBlink: false)
    let applied = captureApply(p)
    p.render.onDown()
    p.render.onDown()  // ブラー行
    p.render.onDown()  // 点滅行
    p.render.onActivate()
    XCTAssertEqual(applied()?.cursorStyleBlink, true)
    XCTAssertTrue(p.render.rows[4].label.contains("オン"))
    XCTAssertNil(p.render.breadcrumb, "潜らない（root のまま）")
  }

  /// 反転は毎回適用（端クランプ無し）。オン→オフへ戻る。
  func testCursorBlinkTogglesBackToOff() {
    let p = model(cursorStyleBlink: true)
    let applied = captureApply(p)
    p.render.onDown()
    p.render.onDown()  // ブラー行
    p.render.onDown()  // 点滅行
    _ = p.render.onRight()
    XCTAssertEqual(applied()?.cursorStyleBlink, false)
    XCTAssertTrue(p.render.rows[4].label.contains("オフ"))
  }

}
