import AppKit
import XCTest

@testable import Orbe

/// 状態アイコン差し替え機能の検証。curated SF Symbols の実在・whole-map（A案）の実効合成と
/// snapshot-on-edit・設定パレットの 2 段ドリル遷移を固定する。libghostty 非依存（純ロジック＋@Observable）。
final class AgentIconTests: XCTestCase {

  // MARK: - curated SF Symbols 実在検証

  /// `AgentStateIcon.curatedSymbols` の全 symbol はビルド機で描画可能（実在しない名は空描画になるため
  /// ここで守る）。全 5 状態を網羅していることも同時に確認する。
  func testCuratedSymbolsExistAndCoverAllKinds() {
    XCTAssertEqual(
      Set(AgentStateIcon.curatedSymbols.keys), Set(AgentStateIcon.Kind.allCases),
      "curated は全 5 状態を網羅する")
    for (kind, names) in AgentStateIcon.curatedSymbols {
      XCTAssertFalse(names.isEmpty, "\(kind) の候補が空でない")
      for name in names {
        XCTAssertNotNil(
          NSImage(systemSymbolName: name, accessibilityDescription: nil),
          "\(name)（\(kind)）は実在する SF Symbol")
      }
    }
  }

  // MARK: - 符号化/復号（永続キー＝状態文字列）

  func testEncodeDecodeRoundTrip() {
    let map: [AgentStateIcon.Kind: String] = [.working: "gearshape", .done: "checkmark.seal"]
    XCTAssertEqual(AgentStateIcon.decode(AgentStateIcon.encode(map)), map)
    XCTAssertEqual(AgentStateIcon.decode(nil), [:], "nil は空マップ＝全 Glass")
    XCTAssertEqual(
      AgentStateIcon.decode(["nope": "x", "working": "gearshape"]), [.working: "gearshape"],
      "未知状態キーは捨てる")
  }

  // MARK: - whole-map（A案）の実効合成

  /// override 非 nil はマップ全体を差し替える（per-key マージしない）。global の working は載らない。
  func testEffectiveWholeMapReplace() {
    var global = SettingsLayer()
    global[SettingKeys.agentStateIcons] = ["working": "gearshape"]
    var override = SettingsLayer()
    override[SettingKeys.agentStateIcons] = ["waiting": "hourglass"]
    let eff = EffectiveSettings(global.overlaid(with: override))
    XCTAssertEqual(eff[SettingKeys.agentStateIcons], ["waiting": "hourglass"])
  }

  /// override が空（未上書き）なら global マップを継承する。
  func testEffectiveInheritsWhenOverrideEmpty() {
    var global = SettingsLayer()
    global[SettingKeys.agentStateIcons] = ["working": "gearshape"]
    let eff = EffectiveSettings(global.overlaid(with: SettingsLayer()))
    XCTAssertEqual(eff[SettingKeys.agentStateIcons], ["working": "gearshape"])
  }

  /// agentStateIcons 単独 override でも層は空でない（isEmpty 畳み込みで消えない）。
  func testAgentStateIconsOverrideAloneIsPreserved() {
    var o = SettingsLayer()
    o[SettingKeys.agentStateIcons] = ["working": "gearshape"]
    XCTAssertFalse(o.isEmpty)
  }

  // MARK: - snapshot-on-edit（未上書き WS の初編集で global マップ全体を所有）

  /// workspace 未上書きで 1 状態を編集すると、実効マップ（＝global）をスナップショットして他状態を保つ。
  func testSnapshotOnEditPreservesOtherStates() {
    let v = values(scope: .workspace, global: [.working: "gearshape"])
    let change = v.agentStateIconChange(kind: .waiting, symbol: "hourglass")
    XCTAssertEqual(change.id, .agentStateIcons)
    guard case .stringMap(let map)? = change.value else { return XCTFail("agentStateIcons 代入でない") }
    XCTAssertEqual(map, ["working": "gearshape", "waiting": "hourglass"], "working が Glass に戻らない")
  }

  /// symbol=nil の選択はその状態をマップから外す（Glass へ戻す）。他状態は保つ。
  func testEditToGlassRemovesOnlyThatState() {
    let v = values(scope: .global, global: [.working: "gearshape", .done: "checkmark.seal"])
    let change = v.agentStateIconChange(kind: .working, symbol: nil)
    guard case .stringMap(let map)? = change.value else { return XCTFail("agentStateIcons 代入でない") }
    XCTAssertEqual(map, ["done": "checkmark.seal"])
  }

  /// 実効 symbol は workspace 上書きを反映する（未上書き field は global を継承）。
  func testEffSymbolReflectsScope() {
    var override = SettingsLayer()
    override[SettingKeys.agentStateIcons] = ["waiting": "hourglass"]
    let v = values(scope: .workspace, global: [.working: "gearshape"], override: override)
    XCTAssertEqual(v.effSymbol(for: .waiting), "hourglass")
    XCTAssertNil(v.effSymbol(for: .working), "override 非 nil は whole-map 差し替え＝working は Glass")
  }

  // MARK: - 設定パレット 2 段ドリル

  /// root → 状態一覧 → アイコン候補 → 確定で状態一覧へ戻り、編集した状態行が選択される。
  /// 確定は whole-map・global スコープで onApply へ届く。
  @MainActor
  func testTwoStageDrillAndWholeMapApply() {
    let p = paletteModel()
    var applied: (SettingChange, SettingsScope)?
    p.onApply = { applied = ($0, $1) }

    p.render.selected = 10  // エージェントアイコン行（root index 10）
    p.render.onActivate()  // → 状態一覧
    XCTAssertEqual(p.render.breadcrumb, "‹ エージェントアイコン")
    XCTAssertEqual(p.render.rows.count, 5, "5 状態一覧")
    XCTAssertNil(p.currentRowIndex, "状態一覧に ● は無い")

    p.render.selected = 0  // working
    p.render.onActivate()  // → アイコン候補
    let working = AgentStateIcon.curatedSymbols[.working] ?? []
    XCTAssertEqual(p.render.breadcrumb, "‹ 実行中")
    XCTAssertEqual(p.render.rows.count, 1 + working.count, "Glass 行＋curated")
    XCTAssertEqual(p.currentRowIndex, 0, "未設定は Glass 行が現在値")
    XCTAssertEqual(p.render.selected, 0)

    p.render.selected = 1  // 先頭 curated
    p.render.onActivate()  // 確定
    guard case .stringMap(let map)? = applied?.0.value else { return XCTFail("whole-map 代入でない") }
    XCTAssertEqual(map, ["working": working[0]])
    XCTAssertEqual(applied?.1, .global)
    XCTAssertEqual(p.render.breadcrumb, "‹ エージェントアイコン", "確定後は状態一覧へ戻る")
    XCTAssertEqual(p.render.selected, 0, "編集した working 行へ選択復元")
  }

  /// アイコン候補の ●／初期ハイライトは現在の実効 symbol の行に乗る（未設定なら Glass 行）。
  @MainActor
  func testIconSubpaletteHighlightsCurrentSymbol() {
    let working = AgentStateIcon.curatedSymbols[.working] ?? []
    let p = paletteModel(agentStateIcons: [.working: working[0]])
    p.render.selected = 10
    p.render.onActivate()  // 状態一覧
    p.render.selected = 0
    p.render.onActivate()  // working のアイコン候補
    XCTAssertEqual(p.currentRowIndex, 1, "現在の symbol 行（Glass の次）に ●")
    XCTAssertEqual(p.render.selected, 1, "初期ハイライトも同じ行")
    XCTAssertTrue(p.render.rows[1].label.contains("● "))
  }

  /// ←／Esc は 1 段ずつ浅く戻り、選択を復元する（アイコン候補→状態一覧→root）。
  @MainActor
  func testBackNavigationIsOneLevelAtATime() {
    let p = paletteModel()
    p.render.selected = 10
    p.render.onActivate()  // 状態一覧
    p.render.selected = 1  // waiting
    p.render.onActivate()  // アイコン候補
    XCTAssertEqual(p.render.breadcrumb, "‹ 入力待ち")
    p.render.onLeft()  // ← → 状態一覧
    XCTAssertEqual(p.render.breadcrumb, "‹ エージェントアイコン")
    XCTAssertEqual(p.render.selected, 1, "潜った waiting 状態行へ復元")
    p.render.onEscape()  // esc → root
    XCTAssertNil(p.render.breadcrumb)
    XCTAssertEqual(p.render.selected, 10, "潜った root 行（エージェントアイコン）へ復元")
  }

  // MARK: - helpers

  private func values(
    scope: SettingsScope, global: [AgentStateIcon.Kind: String],
    override: SettingsLayer = SettingsLayer()
  ) -> ScopedSettingsValues {
    var g = SettingsLayer()
    g[SettingKeys.agentStateIcons] = AgentStateIcon.encode(global)
    return ScopedSettingsValues(scope: scope, global: g, override: override)
  }

  @MainActor
  private func paletteModel(agentStateIcons: [AgentStateIcon.Kind: String] = [:])
    -> SettingsPaletteModel
  {
    var g = SettingsLayer()
    g[SettingKeys.agentStateIcons] = AgentStateIcon.encode(agentStateIcons)
    return SettingsPaletteModel(
      values: ScopedSettingsValues(global: g), fontNames: [], agents: [],
      localization: LocalizationStore(language: .ja))
  }
}
