import XCTest

@testable import Orbe

/// 設定パレット（SettingsPaletteModel・ドリルイン式）のロジック検証。
/// libghostty 非依存（@Observable モデルのみ）。キー意図（move/activate/leftArrow/rightArrow/escape）と
/// 絞り込み（queryChange）の写像でモデルを駆動し、行・選択・コールバックで振る舞いを固定する。
@MainActor
final class SettingsPaletteTests: XCTestCase {
  // model / captureApply は font 拡張（SettingsPaletteFontTests.swift）も使うため非 private。
  func model(
    fontSize: Int = 12, backgroundOpacity: Int = 90, backgroundBlur: Bool = false,
    cursorStyleBlink: Bool = false,
    fontFamily: String? = nil, theme: ThemeMode? = nil,
    defaultAgent: String? = nil, devFeaturesEnabled: Bool = false, fontNames: [String] = [],
    agents: [String] = ["claude", "codex", "agy"],
    scope: SettingsScope = .global,
    override: SettingsLayer = SettingsLayer()
  ) -> SettingsPaletteModel {
    var global = SettingsLayer()
    global[SettingKeys.fontSize] = fontSize
    global[SettingKeys.backgroundOpacity] = backgroundOpacity
    global[SettingKeys.backgroundBlur] = backgroundBlur
    global[SettingKeys.cursorStyleBlink] = cursorStyleBlink
    global[SettingKeys.devFeaturesEnabled] = devFeaturesEnabled
    global[SettingKeys.theme] = theme
    global[SettingKeys.fontFamily] = fontFamily
    global[SettingKeys.defaultAgent] = defaultAgent
    return SettingsPaletteModel(
      values: ScopedSettingsValues(scope: scope, global: global, override: override),
      fontNames: fontNames, agents: agents,
      localization: LocalizationStore(language: .ja))
  }

  /// 適用を捕捉する（単一代入を空レイヤに当てて結果を観測）。
  func captureApply(_ p: SettingsPaletteModel) -> () -> SettingsLayer? {
    var applied: SettingsLayer?
    p.onApply = { change, _ in
      var layer = SettingsLayer()
      layer.apply(change)
      applied = layer
    }
    return { applied }
  }

  /// root からテーマ行（index 5）まで ↓ で降りる。
  func moveToThemeRow(_ p: SettingsPaletteModel) {
    p.render.onDown()  // 不透明度行
    p.render.onDown()  // ブラー行
    p.render.onDown()  // 点滅行
    p.render.onDown()  // テーマ行
  }

  // MARK: - root: 現在値表示・ナビ

  func testRootShowsCurrentValues() {
    let p = model(fontSize: 14, theme: .dark, defaultAgent: "codex")
    XCTAssertTrue(p.render.rows[1].label.contains("14pt"))
    XCTAssertTrue(p.render.rows[5].label.contains("Dark"))
    XCTAssertTrue(p.render.rows[6].label.contains("codex"))
  }

  /// 背景の不透明度行（index 2）は既定 90% を単位つきで出す。
  func testRootShowsBackgroundOpacity() {
    let p = model(backgroundOpacity: 90)
    XCTAssertTrue(p.render.rows[2].label.contains("90%"))
  }

  /// 未設定の現在値は「実際に効いている値」へ解決して出す（テーマ＝Auto、エージェント＝解決済み
  /// デフォルト＝検出先頭、フォント＝既定の実フォント名）。
  func testRootDefaultsWhenUnset() {
    let p = model()
    XCTAssertTrue(p.render.rows[5].label.contains("Auto"), "テーマ未設定は Auto（OS 追従）を表示")
    XCTAssertTrue(
      p.render.rows[6].label.contains("claude"), "エージェント未設定は解決済みデフォルト（検出先頭）を表示")
    XCTAssertFalse(p.render.rows[6].label.contains("（未設定）"))
  }

  /// 検出ゼロで解決不能のときだけエージェント行は「（未設定）」へ縮退する。
  func testRootAgentUnsetPlaceholderWhenNoneDetected() {
    let p = model(agents: [])
    XCTAssertTrue(p.render.rows[6].label.contains("（未設定）"))
  }

  /// root 行の chevron は descriptor.isDrillIn を反映（先頭のスコープ行と stepper/toggle 行は無し、
  /// drillIn 行は有り）。
  func testRootRowChevronsReflectDrillIn() {
    let p = model()
    XCTAssertEqual(
      p.render.rows.map(\.chevron),
      [false, false, false, false, false, true, true, true, true, true, true, false, true, true],
      "スコープ/stepper/toggle 行は chevron 無し、drillIn 各行と worktree 作成先（textInput）・言語行は有り"
    )
  }

  // MARK: - font-size: ←→ 増減とクランプ

  func testFontSizeIncrement() {
    let p = model(fontSize: 12)
    let applied = captureApply(p)
    _ = p.render.onRight()  // フォントサイズ行（初期選択・index 1）で → 増
    XCTAssertEqual(applied()?.fontSize, 13)
    XCTAssertTrue(p.render.rows[1].label.contains("13pt"))
  }

  func testFontSizeDecrement() {
    let p = model(fontSize: 12)
    let applied = captureApply(p)
    p.render.onLeft()  // ← 減
    XCTAssertEqual(applied()?.fontSize, 11)
  }

  func testFontSizeClampLow() {
    let p = model(fontSize: 6)
    let applied = captureApply(p)
    p.render.onLeft()
    XCTAssertNil(applied(), "下端 6 で ← は適用しない（クランプ）")
    XCTAssertTrue(p.render.rows[1].label.contains("6pt"))
  }

  func testFontSizeClampHigh() {
    let p = model(fontSize: 72)
    let applied = captureApply(p)
    _ = p.render.onRight()
    XCTAssertNil(applied(), "上端 72 で → は適用しない（クランプ）")
    XCTAssertTrue(p.render.rows[1].label.contains("72pt"))
  }

  func testFontSizeRowEnterAndLeftElsewhereAreNoop() {
    let p = model(fontSize: 12)
    let applied = captureApply(p)
    p.render.onActivate()  // フォントサイズ行の Enter は no-op
    moveToThemeRow(p)  // テーマ行（drillIn）へ
    p.render.onLeft()  // drillIn 行の ← は no-op（減算/反転は stepper/toggle 行のみ）
    XCTAssertNil(applied())
  }

  // MARK: - theme: Auto / Dark / Light の固定3択

  /// theme サブパレットは絞り込み欄なしの固定3行（見本 Settings 画面の Seg 順）で、
  /// 現在の実効値（未設定は Auto）に ● とハイライトが乗る。
  func testThemeSubpaletteShowsFixedThreeRows() {
    let p = model()
    moveToThemeRow(p)
    p.render.onActivate()  // theme へ潜る
    XCTAssertEqual(p.render.breadcrumb, "‹ テーマ")
    XCTAssertFalse(p.render.fieldVisible, "theme サブパレットに絞り込み入力欄は無い")
    XCTAssertEqual(p.render.rows.map(\.label), ["● Auto", "  Dark", "  Light"])
    XCTAssertEqual(p.render.selected, 0, "未設定（Auto）の行が初期ハイライト")
  }

  /// 設定済みの実効値（Dark）に ● が付き、初期ハイライトも同じ行に乗る。
  func testThemeMarksCurrentEffectiveValue() {
    let p = model(theme: .dark)
    moveToThemeRow(p)
    _ = p.render.onRight()  // → でも潜れる（Enter と同等）
    XCTAssertEqual(p.render.rows.map(\.label), ["  Auto", "● Dark", "  Light"])
    XCTAssertEqual(p.render.selected, 1, "現在値 Dark の行が初期ハイライト（先頭でない）")
  }

  /// 完了条件 1・2・5: theme=Light（global）で潜ると ● と初期ハイライトが Light 行（末尾）に揃って乗り、
  /// そのまま ↵ すると現在値がそのまま確定する（ハイライト＝↵ の着地点）。
  func testThemeHighlightAndMarkerLandOnCurrentValue() {
    let p = model(theme: .light)
    moveToThemeRow(p)
    p.render.onActivate()  // theme へ潜る
    XCTAssertEqual(p.render.selected, 2, "現在値 Light の行がハイライト")
    XCTAssertEqual(
      p.render.rows.map(\.label), ["  Auto", "  Dark", "● Light"], "● も同じ Light 行だけに付く")
    let applied = captureApply(p)
    p.render.onActivate()  // ハイライト行をそのまま確定
    XCTAssertEqual(applied()?.theme, .light, "↵ の着地点はハイライト行＝現在値（別の値へ化けない）")
  }

  /// Dark を選んで Enter → .theme(.dark) を適用して root へ戻り、テーマ行が Dark になる。
  func testThemeSelectDarkAppliesAndReturnsToRoot() {
    let p = model()
    moveToThemeRow(p)
    p.render.onActivate()  // theme へ（selected=0=Auto）
    p.render.onDown()  // Dark
    let applied = captureApply(p)
    p.render.onActivate()  // Enter で確定
    XCTAssertEqual(applied()?.theme, .dark)
    XCTAssertNil(p.render.breadcrumb, "root へ戻る")
    XCTAssertTrue(p.render.rows[5].label.contains("Dark"), "root へ戻りテーマ行が更新される")
  }

  /// Auto の明示選択も適用される（workspace スコープでは「global が dark でも OS 追従」を意味する）。
  func testThemeSelectAutoAppliesExplicitAuto() {
    let p = model(theme: .light)
    moveToThemeRow(p)
    p.render.onActivate()  // theme へ（selected=2=現在値 Light）
    p.render.onUp()  // Dark
    p.render.onUp()  // Auto
    let applied = captureApply(p)
    p.render.onActivate()  // Auto を確定
    XCTAssertEqual(applied()?.theme, .auto)
    XCTAssertTrue(p.render.rows[5].label.contains("Auto"), "テーマ行は Auto 表示へ")
  }

  // MARK: - Esc / ← の段階戻り

  func testEscStagedBack() {
    let p = model()
    var dismissed = false
    p.onDismiss = { dismissed = true }
    moveToThemeRow(p)
    p.render.onActivate()  // theme へ
    p.render.onEscape()  // root へ戻る（閉じない）
    XCTAssertFalse(dismissed)
    XCTAssertNil(p.render.breadcrumb, "root に breadcrumb は無い")
    p.render.onEscape()  // root の Esc は閉じる
    XCTAssertTrue(dismissed)
  }

  func testLeftFromAgentReturnsToRoot() {
    let p = model(defaultAgent: "claude")
    p.render.onDown()
    p.render.onDown()
    p.render.onDown()
    p.render.onDown()
    p.render.onDown()  // エージェント行（index 6）
    p.render.onActivate()  // agent へ
    XCTAssertEqual(p.render.breadcrumb, "‹ デフォルトエージェント")
    p.render.onLeft()  // ← で root へ
    XCTAssertNil(p.render.breadcrumb)
  }

  /// theme は入力欄なしサブパレット（agent と同型）＝ ← で root へ戻る。
  func testLeftFromThemeReturnsToRoot() {
    let p = model()
    moveToThemeRow(p)
    p.render.onActivate()  // theme へ
    XCTAssertEqual(p.render.breadcrumb, "‹ テーマ")
    p.render.onLeft()  // ← で root へ
    XCTAssertNil(p.render.breadcrumb)
  }

  /// theme → root（←）で選択が「テーマ」行へ復元され、root カードへ focus を取り戻す。
  func testReturnFromThemeRestoresSelectionAndFocus() {
    let p = model()
    moveToThemeRow(p)  // テーマ行（index 5）を選択
    p.render.onActivate()  // theme へ潜る
    let tokenInTheme = p.render.focusToken
    p.render.onLeft()  // ← で root へ
    XCTAssertEqual(p.render.selected, 5, "潜った「テーマ」行へ選択を復元（0 リセットしない）")
    XCTAssertGreaterThan(p.render.focusToken, tokenInTheme, "root カードへ focus を取り戻す")
  }

  /// agent → root（Esc）で選択が「デフォルトエージェント」行へ復元され、focus を取り戻す。
  func testReturnFromAgentRestoresSelectionAndFocus() {
    let p = model(defaultAgent: "claude")
    p.render.onDown()
    p.render.onDown()
    p.render.onDown()
    p.render.onDown()
    p.render.onDown()  // エージェント行（index 6）を選択
    p.render.onActivate()  // agent へ潜る
    let tokenInAgent = p.render.focusToken
    p.render.onEscape()  // Esc で root へ
    XCTAssertEqual(p.render.selected, 6, "潜った「デフォルトエージェント」行へ選択を復元")
    XCTAssertGreaterThan(p.render.focusToken, tokenInAgent, "root カードへ focus を取り戻す")
  }

  /// 確定（theme 適用）で root へ戻る場合も選択は「テーマ」行へ復元される。
  func testReturnAfterThemeApplyRestoresSelection() {
    let p = model()
    moveToThemeRow(p)
    p.render.onActivate()  // theme へ
    p.render.onDown()  // Dark（index 1）を選択
    p.render.onActivate()  // Dark を適用 → root へ
    XCTAssertEqual(p.render.selected, 5, "適用後の戻りも「テーマ」行へ復元")
  }

  func testScrimTapDismisses() {
    let p = model()
    var dismissed = false
    p.onDismiss = { dismissed = true }
    p.render.onScrimTap()
    XCTAssertTrue(dismissed)
  }
}

/// パレットテストが `captureApply` の結果を旧来の field 名で読むための typed アクセサ（テスト専用の糖衣）。
extension SettingsLayer {
  var fontSize: Int? { self[SettingKeys.fontSize] }
  var backgroundOpacity: Int? { self[SettingKeys.backgroundOpacity] }
  var backgroundBlur: Bool? { self[SettingKeys.backgroundBlur] }
  var cursorStyleBlink: Bool? { self[SettingKeys.cursorStyleBlink] }
  var theme: ThemeMode? { self[SettingKeys.theme] }
  var fontFamily: String? { self[SettingKeys.fontFamily] }
}
