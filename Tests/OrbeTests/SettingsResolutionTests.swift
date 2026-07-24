import XCTest

@testable import Orbe

/// 設定解決チェーンの純ロジック検証（App 層・I/O 非依存）。
/// 均一レイヤの `overlaid`/`apply`/`isEmpty`・`EffectiveSettings` の既定解決・`SettingChange(key:jsonValue:)`
/// の受理/拒否（registry domain 駆動・null 解除）を固定する。担体が均一な層になったため scopable 集合の
/// 一致テストは消える（構造上ズレ得ない）。
final class SettingsResolutionTests: XCTestCase {

  // MARK: - SettingsLayer: overlaid（override が非 nil 項目で勝つ）

  /// override 層の持つ項目だけが上に被り、持たない項目は base（global）を通す。
  func testOverlaidOverridesOnlyPresentKeys() {
    var global = SettingsLayer()
    global[SettingKeys.fontSize] = 12
    global[SettingKeys.theme] = .light
    global[SettingKeys.backgroundOpacity] = 90
    var override = SettingsLayer()
    override[SettingKeys.fontSize] = 20
    override[SettingKeys.theme] = .dark

    let merged = global.overlaid(with: override)
    XCTAssertEqual(merged[SettingKeys.fontSize], 20, "override が勝つ")
    XCTAssertEqual(merged[SettingKeys.theme], .dark, "override が勝つ")
    XCTAssertEqual(merged[SettingKeys.backgroundOpacity], 90, "override に無い項目は base を通す")
  }

  /// 空 override を重ねても base と同値（純粋な継承）。
  func testOverlaidWithEmptyIsBase() {
    var global = SettingsLayer()
    global[SettingKeys.fontSize] = 14
    global[SettingKeys.fontFamily] = "Menlo"
    XCTAssertEqual(global.overlaid(with: SettingsLayer()), global)
  }

  /// 全項目を別値で重ね、1 項目でも取りこぼせば base 値が残って落ちる（重ね漏れの一括検知）。
  func testOverlaidCoversAllSettings() {
    var global = SettingsLayer()
    global[SettingKeys.fontSize] = 12
    global[SettingKeys.backgroundOpacity] = 90
    global[SettingKeys.backgroundBlur] = false
    global[SettingKeys.cursorStyleBlink] = false
    global[SettingKeys.theme] = .light
    global[SettingKeys.fontFamily] = "Menlo"
    global[SettingKeys.defaultAgent] = "claude"
    global[SettingKeys.devFeaturesEnabled] = false
    global[SettingKeys.agentStateIcons] = ["working": "gearshape"]

    var override = SettingsLayer()
    override[SettingKeys.fontSize] = 20
    override[SettingKeys.backgroundOpacity] = 50
    override[SettingKeys.backgroundBlur] = true
    override[SettingKeys.cursorStyleBlink] = true
    override[SettingKeys.theme] = .dark
    override[SettingKeys.fontFamily] = "Hack"
    override[SettingKeys.defaultAgent] = "codex"
    override[SettingKeys.devFeaturesEnabled] = true
    override[SettingKeys.agentStateIcons] = ["waiting": "hourglass"]

    let eff = EffectiveSettings(global.overlaid(with: override))
    XCTAssertEqual(eff[SettingKeys.fontSize], 20)
    XCTAssertEqual(eff[SettingKeys.backgroundOpacity], 50)
    XCTAssertEqual(eff[SettingKeys.backgroundBlur], true)
    XCTAssertEqual(eff[SettingKeys.cursorStyleBlink], true)
    XCTAssertEqual(eff[SettingKeys.theme], .dark)
    XCTAssertEqual(eff[SettingKeys.fontFamily], "Hack")
    XCTAssertEqual(eff[SettingKeys.defaultAgent], "codex")
    XCTAssertEqual(eff[SettingKeys.devFeaturesEnabled], true)
    XCTAssertEqual(eff[SettingKeys.agentStateIcons], ["waiting": "hourglass"])
  }

  // MARK: - SettingsLayer: apply / isEmpty

  /// apply は非 nil で書き、nil で除去する（解除して継承へ）。
  func testApplyWritesAndRemoves() {
    var layer = SettingsLayer()
    layer.apply(SettingChange(SettingKeys.fontSize, 18))
    XCTAssertEqual(layer[SettingKeys.fontSize], 18)
    layer.apply(SettingChange(id: .fontSize, value: nil))
    XCTAssertNil(layer[SettingKeys.fontSize], "nil 代入で除去")
    XCTAssertTrue(layer.isEmpty, "唯一の項目を除去したら空")
  }

  /// isEmpty は 1 項目でもあれば false（空上書きの nil 畳み込みの判定源）。
  func testIsEmpty() {
    XCTAssertTrue(SettingsLayer().isEmpty)
    var layer = SettingsLayer()
    layer[SettingKeys.cursorStyleBlink] = true
    XCTAssertFalse(layer.isEmpty)
  }

  // MARK: - EffectiveSettings: 既定解決

  /// DefaultedSettingKey は未設定で既定へ解決し（non-nil）、明示値があればそれを返す。
  func testEffectiveResolvesDefaults() {
    let empty = EffectiveSettings(SettingsLayer())
    XCTAssertEqual(empty[SettingKeys.fontSize], 12, "未設定は既定 12")
    XCTAssertEqual(empty[SettingKeys.backgroundOpacity], 95)
    XCTAssertEqual(empty[SettingKeys.theme], .auto, "未設定は既定 .auto")
    XCTAssertEqual(empty[SettingKeys.cursorStyleBlink], true)
    var layer = SettingsLayer()
    layer[SettingKeys.fontSize] = 20
    XCTAssertEqual(EffectiveSettings(layer)[SettingKeys.fontSize], 20, "明示値が既定に勝つ")
  }

  /// unset 意味を持つ key（fontFamily/defaultAgent）は未設定で nil のまま（既定へ解決しない）。
  func testEffectiveKeepsUnsetForOptionalKeys() {
    let empty = EffectiveSettings(SettingsLayer())
    XCTAssertNil(empty[SettingKeys.fontFamily])
    XCTAssertNil(empty[SettingKeys.defaultAgent])
  }

  // MARK: - SettingChange(key:jsonValue:)（control config_set の受理/拒否）

  /// 正常系: 型・値域内の値が該当項目の SettingChange になる。値域境界は registry を SSOT に読む。
  func testInitAcceptsValidTypedValues() {
    let fs = SettingsRegistry.stepperDomain(.fontSize).range
    XCTAssertEqual(
      SettingChange(key: "font-size", jsonValue: fs.lowerBound),
      SettingChange(SettingKeys.fontSize, fs.lowerBound))
    XCTAssertEqual(
      SettingChange(key: "font-size", jsonValue: fs.upperBound),
      SettingChange(SettingKeys.fontSize, fs.upperBound))

    XCTAssertEqual(
      SettingChange(key: "background-blur", jsonValue: true),
      SettingChange(SettingKeys.backgroundBlur, true))
    XCTAssertEqual(
      SettingChange(key: "cursor-style-blink", jsonValue: false),
      SettingChange(SettingKeys.cursorStyleBlink, false))

    XCTAssertEqual(
      SettingChange(key: "theme", jsonValue: "dark"), SettingChange(SettingKeys.theme, .dark))
    // 完了条件7-④: auto は明示値として受理する（nil へ丸めない）。
    XCTAssertEqual(
      SettingChange(key: "theme", jsonValue: "auto"), SettingChange(SettingKeys.theme, .auto))

    if let font = FontCatalog.names().first {
      XCTAssertEqual(
        SettingChange(key: "font-family", jsonValue: font),
        SettingChange(SettingKeys.fontFamily, font))
    }

    // 完了条件7-③: dev-features / agent-state-icons が受理側に移る。
    XCTAssertEqual(
      SettingChange(key: "dev-features", jsonValue: true),
      SettingChange(SettingKeys.devFeaturesEnabled, true))
    XCTAssertEqual(
      SettingChange(key: "agent-state-icons", jsonValue: ["working": "gearshape"]),
      SettingChange(SettingKeys.agentStateIcons, ["working": "gearshape"]))
    // default-agent も受理（全設定 WS 可・専用経路は撤廃）。
    XCTAssertEqual(
      SettingChange(key: "default-agent", jsonValue: "claude"),
      SettingChange(SettingKeys.defaultAgent, "claude"))

    // tab-title-font-family は開いた列挙（defaultAgent 前例）＝任意文字列を受理する。
    // 解決不能名は保存値として保持し、描画時解決で既定へ退避する（ChromeFontResolver）。
    XCTAssertEqual(
      SettingChange(key: "tab-title-font-family", jsonValue: "存在しないファミリ名"),
      SettingChange(SettingKeys.tabTitleFontFamily, "存在しないファミリ名"))
    // emoji-font は閉じた列挙（noto/apple のみ受理）。
    XCTAssertEqual(
      SettingChange(key: "emoji-font", jsonValue: "apple"),
      SettingChange(SettingKeys.emojiFont, .apple))
    XCTAssertNil(SettingChange(key: "emoji-font", jsonValue: "twemoji"), "不正 enum")
  }

  /// null 解除: 任意 key の JSON null は value=nil の SettingChange（継承へ戻す一様な契約）。
  func testInitAcceptsNullAsUnset() {
    XCTAssertEqual(
      SettingChange(key: "theme", jsonValue: NSNull()), SettingChange(id: .theme, value: nil))
    XCTAssertEqual(
      SettingChange(key: "font-family", jsonValue: NSNull()),
      SettingChange(id: .fontFamily, value: nil))
    XCTAssertEqual(
      SettingChange(key: "font-size", jsonValue: NSNull()),
      SettingChange(id: .fontSize, value: nil))
  }

  /// 拒否系（nil）: 未知 key・型不一致・値域外・不正 enum・catalog 外 family・空文字 theme。
  func testInitRejectsUnknownTypeMismatchAndOutOfDomain() {
    XCTAssertNil(SettingChange(key: "no-such-key", jsonValue: 12))

    XCTAssertNil(SettingChange(key: "font-size", jsonValue: "12"), "Int 期待に String")
    XCTAssertNil(SettingChange(key: "background-blur", jsonValue: 1), "Bool 期待に Int")
    XCTAssertNil(SettingChange(key: "theme", jsonValue: 1), "String 期待に Int")
    XCTAssertNil(SettingChange(key: "font-family", jsonValue: 1), "String 期待に Int")
    XCTAssertNil(SettingChange(key: "agent-state-icons", jsonValue: "notamap"), "map 期待に String")

    let fs = SettingsRegistry.stepperDomain(.fontSize).range
    XCTAssertNil(SettingChange(key: "font-size", jsonValue: fs.lowerBound - 1), "下端未満")
    XCTAssertNil(SettingChange(key: "font-size", jsonValue: fs.upperBound + 1), "上端超過")
    let bo = SettingsRegistry.stepperDomain(.backgroundOpacity).range
    XCTAssertNil(SettingChange(key: "background-opacity", jsonValue: bo.lowerBound - 1), "下端未満")
    XCTAssertNil(SettingChange(key: "background-opacity", jsonValue: bo.upperBound + 1), "上端超過")

    // 完了条件7-④: 空文字 theme はもう解除語でない（値域外＝拒否。解除は null）。
    XCTAssertNil(SettingChange(key: "theme", jsonValue: ""), "空文字 theme は拒否（解除は null）")
    XCTAssertNil(SettingChange(key: "theme", jsonValue: "solarized"), "不正 enum")
    XCTAssertNil(
      SettingChange(key: "font-family", jsonValue: "__no_such_font__"), "catalog 外 family")
  }

  // MARK: - worktree-path（pathTemplate domain・唯一の検証点）

  /// 妥当テンプレは受理、null は解除。不正（空・{slug} 欠落・未知トークン・型不一致）は拒否。
  func testWorktreePathValidationThroughSettingChange() {
    XCTAssertEqual(
      SettingChange(key: "worktree-path", jsonValue: "~/wt/{repo}/{slug}"),
      SettingChange(SettingKeys.worktreePath, "~/wt/{repo}/{slug}"))
    XCTAssertEqual(
      SettingChange(key: "worktree-path", jsonValue: WorktreePathTemplate.defaultTemplate),
      SettingChange(SettingKeys.worktreePath, WorktreePathTemplate.defaultTemplate))
    XCTAssertEqual(
      SettingChange(key: "worktree-path", jsonValue: NSNull()),
      SettingChange(id: .worktreePath, value: nil), "null は解除（既定へ戻す）")

    XCTAssertNil(SettingChange(key: "worktree-path", jsonValue: ""), "空は拒否")
    XCTAssertNil(SettingChange(key: "worktree-path", jsonValue: "wt/no-token"), "{slug} 欠落は拒否")
    XCTAssertNil(SettingChange(key: "worktree-path", jsonValue: "{foo}/{slug}"), "未知トークンは拒否")
    XCTAssertNil(SettingChange(key: "worktree-path", jsonValue: 1), "String 期待に Int")
  }
}
