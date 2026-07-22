import XCTest

@testable import Orbe

/// 設定パレットの「背景の不透明度」stepper 行（root index 2）の検証。
/// `SettingsPaletteTests` の拡張として helper（`model`/`captureApply`）を共有する。
/// fontSize stepper と対称に ←→ で 1%刻み増減し 20〜100% でクランプする。
@MainActor
extension SettingsPaletteTests {
  /// 不透明度行は root index 2 に既定 90% を単位つきで出し、chevron を持たない（stepper）。
  func testBackgroundOpacityRowAppearsWithDefault() {
    let p = model(backgroundOpacity: 90)
    XCTAssertTrue(p.render.rows[2].label.contains("90%"), "既定 90% を単位つきで表示")
    XCTAssertFalse(p.render.rows[2].chevron, "stepper 行は chevron を持たない")
  }

  func testBackgroundOpacityIncrement() {
    let p = model(backgroundOpacity: 90)
    let applied = captureApply(p)
    p.render.onDown()  // 不透明度行（index 2）を選択
    _ = p.render.onRight()  // → で 1% 増
    XCTAssertEqual(applied()?.backgroundOpacity, 91)
    XCTAssertTrue(p.render.rows[2].label.contains("91%"))
  }

  func testBackgroundOpacityDecrement() {
    let p = model(backgroundOpacity: 90)
    let applied = captureApply(p)
    p.render.onDown()  // 不透明度行を選択
    p.render.onLeft()  // ← で 1% 減
    XCTAssertEqual(applied()?.backgroundOpacity, 89)
    XCTAssertTrue(p.render.rows[2].label.contains("89%"))
  }

  func testBackgroundOpacityClampHigh() {
    let p = model(backgroundOpacity: 100)
    let applied = captureApply(p)
    p.render.onDown()
    _ = p.render.onRight()
    XCTAssertNil(applied(), "上端 100% で → は適用しない（クランプ）")
    XCTAssertTrue(p.render.rows[2].label.contains("100%"))
  }

  func testBackgroundOpacityClampLow() {
    let p = model(backgroundOpacity: 20)
    let applied = captureApply(p)
    p.render.onDown()
    p.render.onLeft()
    XCTAssertNil(applied(), "下端 20% で ← は適用しない（クランプ）")
    XCTAssertTrue(p.render.rows[2].label.contains("20%"))
  }

  /// stepper 行は潜らない（Enter は no-op・drillIn しない）＝ fontSize と同じ。
  func testBackgroundOpacityRowEnterIsNoop() {
    let p = model(backgroundOpacity: 90)
    let applied = captureApply(p)
    p.render.onDown()  // 不透明度行を選択
    p.render.onActivate()  // Enter は no-op
    XCTAssertNil(applied())
    XCTAssertNil(p.render.breadcrumb, "潜らない（root のまま）")
  }

  /// stepper 汎用化（adjustStepper の switch on id）の回帰ガード。fontSize と backgroundOpacity は
  /// 別プロパティ・別 settings フィールドに独立して書かれる——片方の増減が他方の値を壊さない
  /// （両者へ二重書き・取り違えなら片方の行表示が道連れで変わり検知できる）。
  func testSteppersAreIndependent() {
    let p = model(fontSize: 12, backgroundOpacity: 90)
    p.render.onDown()  // 不透明度行（index 2）へ
    _ = p.render.onRight()  // 不透明度 +1
    XCTAssertTrue(p.render.rows[2].label.contains("91%"), "不透明度は 91% へ")
    XCTAssertTrue(p.render.rows[1].label.contains("12pt"), "fontSize は道連れで変わらない")

    p.render.onUp()  // fontSize 行（index 1）へ
    _ = p.render.onRight()  // fontSize +1
    XCTAssertTrue(p.render.rows[1].label.contains("13pt"), "fontSize は 13pt へ")
    XCTAssertTrue(p.render.rows[2].label.contains("91%"), "不透明度は 91% のまま不変")
  }
}
