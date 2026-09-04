import XCTest

@testable import Orbe

/// 設定パレットの「メニューバー通知の表示時間」stepper 行の検証。
/// `SettingsPaletteTests` の拡張として helper（`model`/`captureApply`）を共有する。
/// 他の stepper と対称に ←→ で 5 秒刻み増減し 5〜180 秒でクランプする。
@MainActor
extension SettingsPaletteTests {
  /// 表示時間行の index（scope 行が 0 なので設定行は +1）。行の同一性から引く——末尾決め打ちだと、
  /// 次に設定を 1 つ足した瞬間に無関係な行を指し、このファイル全体が原因の読めない失敗を出す。
  private var dwellRow: Int {
    SettingsRegistry.rootOrder.firstIndex { $0.id == .menuBarNotificationDuration }! + 1
  }

  /// 表示時間行は既定 40 秒を単位つきで出し、chevron を持たない（stepper）。
  func testMenuBarNotificationDurationRowAppearsWithDefault() {
    let p = model()
    XCTAssertTrue(p.render.rows[dwellRow].label.contains("メニューバー通知の表示時間"))
    XCTAssertTrue(p.render.rows[dwellRow].label.contains("40秒"), "未設定なら既定 40 秒を単位つきで表示")
    XCTAssertFalse(p.render.rows[dwellRow].chevron, "stepper 行は chevron を持たない")
  }

  /// 英語は単位を空白で切って `40 s` と出す（日本語は `40秒` と密着）。
  /// 単位の付け方が言語で割れるので、秒数の値表示は書式ごと言語辞書が持つ。
  func testMenuBarNotificationDurationRowSeparatesTheUnitInEnglish() {
    let p = model(menuBarNotificationDuration: 40, language: .en)
    XCTAssertTrue(p.render.rows[dwellRow].label.contains("Menu Bar Notification Duration"))
    XCTAssertTrue(p.render.rows[dwellRow].label.contains("40 s"), "英語は数と単位の間を空ける")
  }

  func testMenuBarNotificationDurationIncrement() {
    let p = model(menuBarNotificationDuration: 40)
    let applied = captureApply(p)
    p.render.selected = dwellRow
    _ = p.render.onRight()  // → で 5 秒増
    XCTAssertEqual(applied()?[SettingKeys.menuBarNotificationDuration], 45)
    XCTAssertTrue(p.render.rows[dwellRow].label.contains("45秒"))
  }

  func testMenuBarNotificationDurationDecrement() {
    let p = model(menuBarNotificationDuration: 40)
    let applied = captureApply(p)
    p.render.selected = dwellRow
    p.render.onLeft()  // ← で 5 秒減
    XCTAssertEqual(applied()?[SettingKeys.menuBarNotificationDuration], 35)
    XCTAssertTrue(p.render.rows[dwellRow].label.contains("35秒"))
  }

  func testMenuBarNotificationDurationClampHigh() {
    let p = model(menuBarNotificationDuration: 180)
    let applied = captureApply(p)
    p.render.selected = dwellRow
    _ = p.render.onRight()
    XCTAssertNil(applied(), "上端 180 秒で → は適用しない（クランプ）")
    XCTAssertTrue(p.render.rows[dwellRow].label.contains("180秒"))
  }

  func testMenuBarNotificationDurationClampLow() {
    let p = model(menuBarNotificationDuration: 5)
    let applied = captureApply(p)
    p.render.selected = dwellRow
    p.render.onLeft()
    XCTAssertNil(applied(), "下端 5 秒で ← は適用しない（クランプ）")
    XCTAssertTrue(p.render.rows[dwellRow].label.contains("5秒"))
  }

  /// stepper 行は潜らない（Enter は no-op）＝ fontSize・音量と同じ。
  func testMenuBarNotificationDurationRowEnterIsNoop() {
    let p = model(menuBarNotificationDuration: 40)
    let applied = captureApply(p)
    p.render.selected = dwellRow
    p.render.onActivate()
    XCTAssertNil(applied())
    XCTAssertNil(p.render.breadcrumb, "潜らない（root のまま）")
  }

  /// workspace スコープでは上書き・「（継承）」表示・delete での継承解除が他の stepper 行と同じに効く。
  func testMenuBarNotificationDurationWorkspaceOverrideAndInherit() {
    var override = SettingsLayer()
    override[SettingKeys.menuBarNotificationDuration] = 90
    let p = model(menuBarNotificationDuration: 40, scope: .workspace, override: override)
    XCTAssertTrue(p.render.rows[dwellRow].label.contains("90秒"), "上書きが実効値として出る")
    XCTAssertFalse(p.render.rows[dwellRow].inherited, "上書き中は継承マーク無し")

    p.render.selected = dwellRow
    p.render.onDelete()  // 上書きを解除して global 継承へ戻す
    XCTAssertTrue(p.render.rows[dwellRow].label.contains("40秒"), "global の 40 秒を継承")
    XCTAssertTrue(p.render.rows[dwellRow].inherited)
    XCTAssertEqual(p.render.rows[dwellRow].detail, "（継承）")
  }
}
