import XCTest

@testable import Orbe

/// 設定パレットの「開発中の機能を有効化」toggle 行（root index 11）の検証。
/// `SettingsPaletteTests` の拡張として helper（`model`）を共有する。
/// 他 toggle（cursor-style-blink 等）と同じ generic な `onApply`（単一代入）経路を通る——非 scopable の
/// 専用経路は撤廃され、workspace スコープでも上書き可能になった。
@MainActor
extension SettingsPaletteTests {
  /// 開発中機能行は root index 11 に既定「オフ」を出し、chevron を持たない（toggle）。
  func testDevFeaturesRowAppearsWithDefault() {
    let p = model(devFeaturesEnabled: false)
    XCTAssertTrue(p.render.rows[11].label.contains("オフ"), "既定オフを表示")
    XCTAssertFalse(p.render.rows[11].chevron, "toggle 行は chevron を持たない")
  }

  /// 開発中機能行（index 11）まで ↓ で降りる（初期選択は fontSize 行 index 1）。
  private func moveToDevFeaturesRow(_ p: SettingsPaletteModel) {
    for _ in 0..<10 { p.render.onDown() }
  }

  /// → で反転（オフ→オン）。onApply が devFeaturesEnabled=true を受け、行表示が追従する。
  func testDevFeaturesToggleWithRight() {
    let p = model(devFeaturesEnabled: false)
    var captured: [SettingChange] = []
    p.onApply = { change, _ in captured.append(change) }
    moveToDevFeaturesRow(p)
    _ = p.render.onRight()
    XCTAssertEqual(captured, [SettingChange(SettingKeys.devFeaturesEnabled, true)])
    XCTAssertTrue(p.render.rows[11].label.contains("オン"))
  }

  /// ← でも反転（stepper と違い減算でなく flip）。
  func testDevFeaturesToggleWithLeft() {
    let p = model(devFeaturesEnabled: false)
    var captured: [SettingChange] = []
    p.onApply = { change, _ in captured.append(change) }
    moveToDevFeaturesRow(p)
    p.render.onLeft()
    XCTAssertEqual(captured, [SettingChange(SettingKeys.devFeaturesEnabled, true)])
    XCTAssertTrue(p.render.rows[11].label.contains("オン"))
  }

  /// Enter でも反転（drillIn と違い潜らず flip）。root のまま。
  func testDevFeaturesToggleWithEnter() {
    let p = model(devFeaturesEnabled: false)
    var captured: [SettingChange] = []
    p.onApply = { change, _ in captured.append(change) }
    moveToDevFeaturesRow(p)
    p.render.onActivate()
    XCTAssertEqual(captured, [SettingChange(SettingKeys.devFeaturesEnabled, true)])
    XCTAssertTrue(p.render.rows[11].label.contains("オン"))
    XCTAssertNil(p.render.breadcrumb, "潜らない（root のまま）")
  }

  /// 反転は毎回適用（端クランプ無し）。オン→オフへ戻る。
  func testDevFeaturesTogglesBackToOff() {
    let p = model(devFeaturesEnabled: true)
    var captured: [SettingChange] = []
    p.onApply = { change, _ in captured.append(change) }
    moveToDevFeaturesRow(p)
    _ = p.render.onRight()
    XCTAssertEqual(captured, [SettingChange(SettingKeys.devFeaturesEnabled, false)])
    XCTAssertTrue(p.render.rows[11].label.contains("オフ"))
  }

  /// 他 toggle と同じ generic 経路——反転は `onApply` に devFeaturesEnabled の単一代入で届く。
  func testDevFeaturesToggleGoesThroughOnApply() {
    let p = model(devFeaturesEnabled: false)
    let applied = captureApply(p)
    moveToDevFeaturesRow(p)
    _ = p.render.onRight()
    XCTAssertEqual(applied()?[SettingKeys.devFeaturesEnabled], true, "onApply 経由で単一代入が届く")
  }

  /// 完了条件2: workspace スコープで devFeatures も上書きできる（onApply に .workspace で届く）。
  func testDevFeaturesOverridableInWorkspaceScope() {
    let p = model(devFeaturesEnabled: false)
    p.render.selected = 0
    p.render.onActivate()  // workspace スコープへ
    var scope: SettingsScope?
    p.onApply = { _, s in scope = s }
    p.render.selected = 11  // 開発中機能行（スコープ切替後は選択がスコープ行に居るため直接置く）
    _ = p.render.onRight()
    XCTAssertEqual(scope, .workspace, "workspace スコープの上書きとして届く")
  }
}
