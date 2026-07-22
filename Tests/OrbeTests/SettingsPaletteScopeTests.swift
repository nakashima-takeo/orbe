import XCTest

@testable import Orbe

/// 設定パレットの P2 スコープトグル（グローバル ⇄ この workspace）と継承/上書き表示・上書き解除の検証。
/// `SettingsPaletteTests` の拡張として helper（`model`）を共有する。
@MainActor
extension SettingsPaletteTests {

  /// 上書き層を組む（テスト用）。
  fileprivate func ov(_ mutate: (inout SettingsLayer) -> Void) -> SettingsLayer {
    var l = SettingsLayer()
    mutate(&l)
    return l
  }

  /// スコープ適用を（単一代入＋スコープ）で捕捉する。
  private func captureScoped(_ p: SettingsPaletteModel) -> () -> [(SettingChange, SettingsScope)] {
    var applies: [(SettingChange, SettingsScope)] = []
    p.onApply = { applies.append(($0, $1)) }
    return { applies }
  }

  /// 先頭（index 0）はスコープ行で既定はグローバル・chevron 無し。
  func testScopeRowShowsGlobalByDefault() {
    let p = model()
    XCTAssertTrue(p.render.rows[0].label.contains("スコープ"))
    XCTAssertTrue(p.render.rows[0].label.contains("グローバル"))
    XCTAssertFalse(p.render.rows[0].chevron, "スコープ行は chevron を持たない")
  }

  /// 先頭（index 0）はスコープ行。↵ でグローバル ⇄ この workspace を反転する。
  func testScopeRowTogglesScope() {
    let p = model()
    XCTAssertTrue(p.render.rows[0].label.contains("グローバル"))
    p.render.selected = 0
    p.render.onActivate()  // ↵ で反転
    XCTAssertTrue(p.render.rows[0].label.contains("この workspace"))
    _ = p.render.onRight()  // → でも反転（グローバルへ戻る）
    XCTAssertTrue(p.render.rows[0].label.contains("グローバル"))
    p.render.onLeft()  // ← でも反転
    XCTAssertTrue(p.render.rows[0].label.contains("この workspace"))
  }

  /// workspace スコープで上書きの無い行は global 値を「（継承）」付き・inherited フラグで示す。
  func testWorkspaceScopeShowsInheritance() {
    let p = model(fontSize: 14, theme: .dark)
    XCTAssertFalse(p.render.rows[1].inherited, "global スコープでは継承表示しない")
    p.render.selected = 0
    p.render.onActivate()  // workspace スコープへ
    XCTAssertTrue(p.render.rows[1].label.contains("14pt"))
    XCTAssertEqual(p.render.rows[1].detail, "（継承）", "上書き無しは global 値を継承表示（muted 補足）")
    XCTAssertTrue(p.render.rows[1].inherited)
    XCTAssertTrue(p.render.rows[5].label.contains("Dark"), "テーマも global を継承表示")
    XCTAssertTrue(p.render.rows[5].inherited)
  }

  /// workspace スコープでの変更は onApply へ .workspace スコープで届き、行は上書き値（継承マーク無し）になる。
  func testWorkspaceScopeApplyRoutesToWorkspace() {
    let p = model(fontSize: 12)
    let applies = captureScoped(p)
    p.render.selected = 0
    p.render.onActivate()  // workspace スコープへ
    p.render.selected = 1  // フォントサイズ行
    _ = p.render.onRight()  // +1 上書き
    XCTAssertEqual(applies().last?.0, SettingChange(SettingKeys.fontSize, 13))
    XCTAssertEqual(applies().last?.1, .workspace)
    XCTAssertTrue(p.render.rows[1].label.contains("13pt"), "上書き値を表示")
    XCTAssertFalse(p.render.rows[1].inherited, "上書き中は継承マーク無し")
  }

  /// global スコープでの変更は onApply へ .global スコープで届く（既存挙動）。
  func testGlobalScopeApplyRoutesToGlobal() {
    let p = model(fontSize: 12)
    let applies = captureScoped(p)
    _ = p.render.onRight()  // フォントサイズ行（初期選択）で +1
    XCTAssertEqual(applies().last?.0, SettingChange(SettingKeys.fontSize, 13))
    XCTAssertEqual(applies().last?.1, .global)
  }

  /// delete で workspace 上書きを解除し、global 継承へ戻る（onApply に nil 代入が届く）。
  func testDeleteClearsWorkspaceOverride() {
    let p = model(fontSize: 12)
    let applies = captureScoped(p)
    p.render.selected = 0
    p.render.onActivate()  // workspace スコープへ
    p.render.selected = 1  // フォントサイズ行
    _ = p.render.onRight()  // 13 へ上書き
    XCTAssertFalse(p.render.rows[1].inherited)
    p.render.onDelete()  // 上書き解除
    XCTAssertEqual(applies().last?.0, SettingChange(id: .fontSize, value: nil))
    XCTAssertEqual(applies().last?.1, .workspace)
    XCTAssertTrue(p.render.rows[1].label.contains("12pt"), "global 値へ継承")
    XCTAssertTrue(p.render.rows[1].inherited)
  }

  /// 上書きの無い行での delete は no-op（継承のまま・onApply を呼ばない）。
  func testDeleteOnInheritedRowIsNoop() {
    let p = model(fontSize: 12)
    p.render.selected = 0
    p.render.onActivate()  // workspace スコープへ
    let applies = captureScoped(p)
    p.render.selected = 1  // 継承中のフォントサイズ行
    p.render.onDelete()
    XCTAssertTrue(applies().isEmpty, "上書きが無ければ delete は何もしない")
  }

  /// global スコープの delete は何もしない（root で誤爆しない）。
  func testDeleteInGlobalScopeIsNoop() {
    let p = model(fontSize: 12)
    let applies = captureScoped(p)
    p.render.selected = 1
    p.render.onDelete()
    XCTAssertTrue(applies().isEmpty)
  }

  /// 完了条件1: defaultAgent 行も workspace スコープで操作可能（全設定 WS 可・非 scopable 例外の撤廃）。
  func testDefaultAgentRowOperableInWorkspaceScope() {
    let p = model(defaultAgent: "claude")
    XCTAssertTrue(p.render.rows[6].enabled, "global スコープでは操作可")
    p.render.selected = 0
    p.render.onActivate()  // workspace スコープへ
    XCTAssertTrue(p.render.rows[6].enabled, "workspace スコープでも操作可（非 scopable 例外は無い）")
    XCTAssertEqual(p.render.rows[6].detail, "（継承）", "未上書きは global を継承表示")
  }

  /// 完了条件6: global スコープでアクティブ WS が上書きしている行は、画面に効いている値を注記する。
  func testGlobalScopeAnnotatesWorkspaceOverride() {
    let p = model(
      fontSize: 14, theme: .light,
      override: ov {
        $0[SettingKeys.fontSize] = 16
        $0[SettingKeys.theme] = .dark
      })
    XCTAssertTrue(p.render.rows[1].label.contains("14pt"), "現在値は global 値（Enter の着地点）")
    XCTAssertEqual(
      p.render.rows[1].detail, "（この WS では 16pt）", "画面に効いている上書き値を muted 補足で注記")
    XCTAssertFalse(p.render.rows[1].label.contains("この WS では"), "注記は主値のラベルへ混ぜない")
    XCTAssertFalse(p.render.rows[1].inherited, "global スコープの注記行は淡色にしない")
    XCTAssertTrue(p.render.rows[5].label.contains("Light"))
    XCTAssertEqual(p.render.rows[5].detail, "（この WS では Dark）", "テーマ行も同じ書式で注記")
    XCTAssertNil(p.render.rows[2].detail, "上書きの無い行には注記を出さない")
  }

  /// global スコープで WS が上書き中でも、サブパレットの ●/ハイライトは global 値に乗る。
  func testGlobalScopeSubpaletteHighlightsGlobalValueNotOverride() {
    let p = model(theme: .light, override: ov { $0[SettingKeys.theme] = .dark })
    moveToThemeRow(p)
    p.render.onActivate()  // theme へ潜る
    XCTAssertEqual(p.render.rows.map(\.label), ["  Auto", "  Dark", "● Light"])
    XCTAssertEqual(p.render.selected, 2, "global 値 Light の行に乗る（WS 上書き Dark ではない）")
  }

  /// workspace スコープでは実効値そのものを出すので「この WS では」注記は出さない（二重表示しない）。
  func testWorkspaceScopeHasNoOverrideNote() {
    let p = model(fontSize: 14, scope: .workspace, override: ov { $0[SettingKeys.fontSize] = 16 })
    XCTAssertTrue(p.render.rows[1].label.contains("16pt"), "上書き値そのものが現在値")
    XCTAssertNil(p.render.rows[1].detail)
  }

  /// 初期スコープ workspace＋既存 override は上書き値を、未上書き field は global 継承を示す。
  func testInitialWorkspaceOverrideDisplayed() {
    let p = model(
      fontSize: 12, theme: .light, agents: [], scope: .workspace,
      override: ov { $0[SettingKeys.theme] = .dark })
    XCTAssertTrue(p.render.rows[5].label.contains("Dark"), "テーマは上書き値")
    XCTAssertFalse(p.render.rows[5].inherited)
    XCTAssertTrue(p.render.rows[1].label.contains("12pt"), "フォントサイズは global 継承")
    XCTAssertTrue(p.render.rows[1].inherited)
  }
}
