import XCTest

@testable import Orbe

/// 設定パレットの「カーソルの点滅」toggle 行（root index 4）の検証。
/// `SettingsPaletteTests` の拡張として helper（`model`/`captureApply`）を共有する。
/// stepper と対称の直接編集行で、←/→/↵ のいずれでも値を反転する（潜らない・chevron 無し）。
@MainActor
extension SettingsPaletteTests {
  /// 点滅行は root index 4 に既定「オフ」を出し、chevron を持たない（toggle）。
  func testCursorBlinkRowAppearsWithDefault() {
    let p = model(cursorStyleBlink: false)
    XCTAssertTrue(p.render.rows[4].label.contains("オフ"), "既定オフを表示")
    XCTAssertFalse(p.render.rows[4].chevron, "toggle 行は chevron を持たない")
  }

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

  /// toggle は stepper と独立——点滅の反転が fontSize/不透明度の行表示を壊さない。
  func testCursorBlinkIndependentFromSteppers() {
    let p = model(fontSize: 12, backgroundOpacity: 90, cursorStyleBlink: false)
    p.render.onDown()
    p.render.onDown()  // ブラー行
    p.render.onDown()  // 点滅行
    _ = p.render.onRight()  // 点滅 → オン
    XCTAssertTrue(p.render.rows[4].label.contains("オン"))
    XCTAssertTrue(p.render.rows[1].label.contains("12pt"), "fontSize は道連れで変わらない")
    XCTAssertTrue(p.render.rows[2].label.contains("90%"), "不透明度は道連れで変わらない")
  }

  /// 逆方向の独立——stepper 操作（fontSize/不透明度の増減）が toggle 行の値/表示を壊さない
  /// （`adjustStepper` が cursorStyleBlink を道連れにしない）。
  func testSteppersIndependentFromCursorBlink() {
    let p = model(fontSize: 12, backgroundOpacity: 90, cursorStyleBlink: true)
    _ = p.render.onRight()  // fontSize 行（index 1）で → 増 → 13pt
    p.render.onDown()  // 不透明度行（index 2）
    p.render.onLeft()  // 不透明度 → 減 → 89%
    XCTAssertTrue(p.render.rows[1].label.contains("13pt"))
    XCTAssertTrue(p.render.rows[2].label.contains("89%"))
    XCTAssertTrue(p.render.rows[4].label.contains("オン"), "点滅は stepper 操作の道連れで変わらない")
  }

  /// toggle 操作と stepper 操作は互いの settings フィールドを取り違えない——
  /// stepper 適用は fontSize のみ・toggle 適用は cursorStyleBlink のみを触る
  /// （`adjustStepper`/`toggleValue` の mutation クロージャが自分の id のフィールドだけを書く）。
  func testToggleAndStepperApplyDistinctFields() {
    let p = model(fontSize: 12, cursorStyleBlink: false)
    var applies: [SettingsLayer] = []
    p.onApply = { change, _ in
      var layer = SettingsLayer()
      layer.apply(change)
      applies.append(layer)
    }
    _ = p.render.onRight()  // fontSize 行（index 1）で → 増 → 適用[0]
    p.render.onDown()  // 不透明度行
    p.render.onDown()  // ブラー行
    p.render.onDown()  // 点滅行（index 4）
    _ = p.render.onRight()  // 点滅 → オン → 適用[1]
    XCTAssertEqual(applies.count, 2, "stepper 増分と toggle 反転でそれぞれ 1 回ずつ適用")
    XCTAssertEqual(applies[0].fontSize, 13, "stepper 適用は fontSize を書く")
    XCTAssertNil(applies[0].cursorStyleBlink, "stepper 適用は toggle フィールドを巻き込まない")
    XCTAssertEqual(applies[1].cursorStyleBlink, true, "toggle 適用は cursorStyleBlink を書く")
    XCTAssertNil(applies[1].fontSize, "toggle 適用は stepper フィールドを巻き込まない")
  }
}
