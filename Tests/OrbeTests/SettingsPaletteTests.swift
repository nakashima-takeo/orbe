import XCTest

@testable import Orbe

/// 設定パレット（SettingsPaletteModel・ドリルイン式）のロジック検証。
/// libghostty 非依存（@Observable モデルのみ）。キー意図（move/activate/leftArrow/rightArrow/escape）と
/// 絞り込み（queryChange）の写像でモデルを駆動し、行・選択・コールバックで振る舞いを固定する。
@MainActor
final class SettingsPaletteTests: OrbeTestCase {
  // model / captureApply は font 拡張（SettingsPaletteFontTests.swift）も使うため非 private。
  func model(
    fontSize: Int? = nil, backgroundOpacity: Int? = nil, backgroundBlur: Bool? = nil,
    cursorStyleBlink: Bool? = nil,
    fontFamily: String? = nil, theme: ThemeMode? = nil,
    defaultAgent: String? = nil, worktreeDir: String? = nil,
    menuBarNotificationDuration: Int? = nil,
    fontNames: [String] = [],
    agents: [String] = ["claude", "codex", "agy"],
    scope: SettingsScope = .global,
    override: SettingsLayer = SettingsLayer(),
    language: Language = .ja
  ) -> SettingsPaletteModel {
    var global = SettingsLayer()
    global[SettingKeys.fontSize] = fontSize
    global[SettingKeys.backgroundOpacity] = backgroundOpacity
    global[SettingKeys.backgroundBlur] = backgroundBlur
    global[SettingKeys.cursorStyleBlink] = cursorStyleBlink
    global[SettingKeys.theme] = theme
    global[SettingKeys.fontFamily] = fontFamily
    global[SettingKeys.defaultAgent] = defaultAgent
    global[SettingKeys.worktreeDir] = worktreeDir
    global[SettingKeys.menuBarNotificationDuration] = menuBarNotificationDuration
    return SettingsPaletteModel(
      values: ScopedSettingsValues(scope: scope, global: global, override: override),
      fontNames: fontNames, agents: agents,
      localization: LocalizationStore(language: language))
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

  /// 未設定の現在値は「実際に効いている値」へ解決して出す（テーマ＝Auto、ブラー＝オン、エージェント＝
  /// 解決済みデフォルト＝検出先頭）。
  func testRootDefaultsWhenUnset() {
    let p = model()
    XCTAssertTrue(p.render.rows[5].label.contains("Auto"), "テーマ未設定は Auto（OS 追従）を表示")
    XCTAssertTrue(p.render.rows[3].label.contains("オン"), "ブラー未設定は既定のオンを表示")
    XCTAssertTrue(
      p.render.rows[6].label.contains("claude"), "エージェント未設定は解決済みデフォルト（検出先頭）を表示")
    XCTAssertFalse(p.render.rows[6].label.contains("（未設定）"))
  }

  /// 検出ゼロで解決不能のときだけエージェント行は「（未設定）」へ縮退する。
  func testRootAgentUnsetPlaceholderWhenNoneDetected() {
    let p = model(agents: [])
    XCTAssertTrue(p.render.rows[6].label.contains("（未設定）"))
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

  /// root での設定行の index（先頭のスコープ行の分 +1）。行の同一性から引く。
  func rootRow(_ id: SettingID) -> Int {
    SettingsRegistry.rootOrder.firstIndex { $0.id == id }! + 1
  }

  /// stepper の値域と刻みは spec の合意値（不透明度 20–100%、表示時間 5–180 秒・5 秒刻み）。
  /// 1 押しで刻み幅だけ動き、端では書かない。フォントサイズは上の 4 本、音量は通知音のテストが持つ。
  func testSteppersMoveByTheirStepAndStopAtTheSpecBounds() {
    struct Stepper {
      let id: SettingID
      let key: DefaultedSettingKey<Int>
      let low: Int
      let high: Int
      let step: Int
    }
    let steppers = [
      Stepper(
        id: .backgroundOpacity, key: SettingKeys.backgroundOpacity, low: 20, high: 100, step: 1),
      Stepper(
        id: .menuBarNotificationDuration, key: SettingKeys.menuBarNotificationDuration,
        low: 5, high: 180, step: 5),
    ]
    for s in steppers {
      func press(from value: Int, _ key: (SettingsPaletteModel) -> Void) -> Int? {
        var global = SettingsLayer()
        global[s.key] = value
        let p = SettingsPaletteModel(
          values: ScopedSettingsValues(scope: .global, global: global, override: SettingsLayer()),
          fontNames: [], agents: [], localization: LocalizationStore(language: .ja))
        let applied = captureApply(p)
        p.render.selected = rootRow(s.id)
        key(p)
        return applied()?[s.key]
      }
      let right: (SettingsPaletteModel) -> Void = { _ = $0.render.onRight() }
      let left: (SettingsPaletteModel) -> Void = { $0.render.onLeft() }
      let mid = s.low + s.step
      XCTAssertEqual(press(from: mid, right), mid + s.step, "\(s.id): → は刻み幅だけ増える")
      XCTAssertEqual(press(from: mid, left), s.low, "\(s.id): ← は刻み幅だけ減る")
      XCTAssertNil(press(from: s.high, right), "\(s.id): 上端で → は書かない")
      XCTAssertNil(press(from: s.low, left), "\(s.id): 下端で ← は書かない")
    }
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
