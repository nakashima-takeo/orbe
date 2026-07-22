import XCTest

@testable import Orbe

/// 設定パレットの agent サブリスト（デフォルトエージェント行・root index 6）の検証。
/// `SettingsPaletteTests` の拡張として helper（`model`）を共有する。
/// 検出済み CLI のみ列挙し、↵ で default を設定（他項目と同じ `onApply` 経路）、空状態は情報行 1 つを出す。
/// 「現在のデフォルト」は `AgentLauncher` と同じ解決済みデフォルト（設定値が検出済みならそれ、無ければ検出先頭）。
@MainActor
extension SettingsPaletteTests {
  /// root からエージェント行（index 6）まで ↓ で降りる。
  private func moveToAgentRow(_ p: SettingsPaletteModel) {
    for _ in 0..<5 { p.render.onDown() }
  }

  // MARK: - agent: サブリスト選択

  func testAgentSelection() {
    let p = model(defaultAgent: "claude")
    moveToAgentRow(p)
    p.render.onActivate()  // 潜る
    XCTAssertTrue(p.render.rows[0].label.contains("● claude"), "現 default に ●")
    XCTAssertEqual(p.render.selected, 0, "現 default の行が初期ハイライト")
    p.render.onDown()  // codex へ
    var set: SettingChange?
    p.onApply = { change, _ in set = change }
    p.render.onActivate()  // 設定（onApply 経由）
    XCTAssertEqual(set, SettingChange(SettingKeys.defaultAgent, "codex"))
    XCTAssertTrue(p.render.rows[6].label.contains("codex"), "root へ戻りエージェント行が更新される")
  }

  /// 完了条件 1・2: 現 default が先頭でなくても ● と初期ハイライトがその行に揃って乗る。
  func testAgentHighlightAndMarkerLandOnCurrentDefault() {
    let p = model(defaultAgent: "codex", agents: ["claude", "codex", "agy"])
    moveToAgentRow(p)
    p.render.onActivate()  // agent へ
    XCTAssertEqual(p.render.selected, 1, "現 default（codex）の行がハイライト")
    XCTAssertEqual(p.render.rows.map(\.label), ["  claude", "● codex", "  agy"])
  }

  /// 完了条件 3: 未設定でも検出先頭へ解決し、●/ハイライト/root 表示がその値を指す。
  func testAgentUnsetResolvesToFirstDetected() {
    let p = model(defaultAgent: nil, agents: ["claude", "codex"])
    XCTAssertTrue(p.render.rows[6].label.contains("claude"), "root も解決済みデフォルトを出す")
    XCTAssertFalse(p.render.rows[6].label.contains("（未設定）"))
    moveToAgentRow(p)
    p.render.onActivate()  // agent へ
    XCTAssertEqual(p.render.rows.map(\.label), ["● claude", "  codex"])
    XCTAssertEqual(p.render.selected, 0)
    XCTAssertEqual(
      AgentLauncher.resolveDefault(configured: nil, detected: ["claude", "codex"]), "claude",
      "起動側の解決規則と同じキー")
  }

  /// 完了条件 3: 設定値が未検出（消えた CLI）でも検出先頭へ解決する。
  func testAgentUnknownDefaultResolvesToFirstDetected() {
    let p = model(defaultAgent: "gone", agents: ["claude", "codex"])
    XCTAssertTrue(p.render.rows[6].label.contains("claude"), "root は未検出の生値でなく解決済みを出す")
    moveToAgentRow(p)
    p.render.onActivate()  // agent へ
    XCTAssertEqual(p.render.rows.map(\.label), ["● claude", "  codex"])
    XCTAssertEqual(p.render.selected, 0)
  }

  // MARK: - agent: 検出済みのみ列挙

  func testAgentListsOnlyDetected() {
    let p = model(defaultAgent: "claude", agents: ["claude", "codex"])  // agy 未検出
    moveToAgentRow(p)
    p.render.onActivate()  // agent へ
    XCTAssertEqual(p.render.rows.map(\.label), ["● claude", "  codex"], "検出済みのみ・agy は出ない")
  }

  func testAgentEmptyStateInfoRowAndNoSet() {
    let p = model(defaultAgent: "claude", agents: [])  // 検出ゼロ
    moveToAgentRow(p)
    p.render.onActivate()  // agent へ
    XCTAssertEqual(p.render.rows.count, 1)
    XCTAssertFalse(p.render.rows[0].enabled, "検出ゼロは情報行 1 つ（空状態）")
    XCTAssertEqual(p.render.selected, 0, "現在値が無い（解決不能）ので選択は先頭")
    var applied = false
    p.onApply = { _, _ in applied = true }
    p.render.onActivate()  // 情報行で Enter → 設定しない
    XCTAssertFalse(applied)
  }
}
