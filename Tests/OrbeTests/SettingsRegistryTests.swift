import XCTest

@testable import Orbe

/// 設定レジストリ（SSOT）の宣言的契約と不変条件の検証。App 層・純ロジック。
/// `all`（gui.conf 正準順）と `rootOrder`（表示順）の 2 順序・key 一意・domain と activation の整合・
/// guiConf 橋渡し・DefaultedSettingKey の既定を固定する。
final class SettingsRegistryTests: XCTestCase {

  private func eff(_ mutate: (inout SettingsLayer) -> Void = { _ in }) -> EffectiveSettings {
    var l = SettingsLayer()
    mutate(&l)
    return EffectiveSettings(l)
  }

  // MARK: - 2 つの順序リスト（別物）

  /// `all` は gui.conf の正準出力順。この順が `GuiConfig.regenerate` の出力バイト順を決める。
  func testAllIsCanonicalGuiConfOrder() {
    XCTAssertEqual(
      SettingsRegistry.all.map(\.id),
      [
        .fontSize, .fontFamily, .tabTitleFontFamily, .emojiFont, .theme, .defaultAgent,
        .backgroundOpacity, .backgroundBlur, .cursorStyleBlink, .agentStateIcons,
        .devFeaturesEnabled,
      ])
  }

  /// `rootOrder` は設定パレット root の表示順。
  func testRootOrderIsDisplayOrder() {
    XCTAssertEqual(
      SettingsRegistry.rootOrder.map(\.id),
      [
        .fontSize, .backgroundOpacity, .backgroundBlur, .cursorStyleBlink, .theme,
        .defaultAgent, .fontFamily, .tabTitleFontFamily, .emojiFont, .agentStateIcons,
        .devFeaturesEnabled,
      ])
  }

  /// 2 順序は SettingID の全 case を過不足なく含む（追加漏れの検知）。
  func testAllAndRootOrderCoverEverySettingID() {
    let allIDs = Set(SettingID.allCases)
    XCTAssertEqual(Set(SettingsRegistry.all.map(\.id)), allIDs, "all が全 case を含む")
    XCTAssertEqual(Set(SettingsRegistry.rootOrder.map(\.id)), allIDs, "rootOrder が全 case を含む")
  }

  // MARK: - key（canonical・SSOT）

  /// key は全項目で固定文字列（config CLI・control config_* が依存する安定 key のリグレッション防止）。
  func testKeyIsStableForAllSettings() {
    XCTAssertEqual(SettingsRegistry.descriptor(.fontSize).key, "font-size")
    XCTAssertEqual(SettingsRegistry.descriptor(.backgroundOpacity).key, "background-opacity")
    XCTAssertEqual(SettingsRegistry.descriptor(.backgroundBlur).key, "background-blur")
    XCTAssertEqual(SettingsRegistry.descriptor(.cursorStyleBlink).key, "cursor-style-blink")
    XCTAssertEqual(SettingsRegistry.descriptor(.theme).key, "theme")
    XCTAssertEqual(SettingsRegistry.descriptor(.defaultAgent).key, "default-agent")
    XCTAssertEqual(SettingsRegistry.descriptor(.fontFamily).key, "font-family")
    XCTAssertEqual(SettingsRegistry.descriptor(.tabTitleFontFamily).key, "tab-title-font-family")
    XCTAssertEqual(SettingsRegistry.descriptor(.emojiFont).key, "emoji-font")
    XCTAssertEqual(SettingsRegistry.descriptor(.agentStateIcons).key, "agent-state-icons")
    XCTAssertEqual(SettingsRegistry.descriptor(.devFeaturesEnabled).key, "dev-features")
    XCTAssertEqual(SettingsRegistry.confKey(.fontSize), "font-size", "confKey は descriptor.key を引く")
    let keys = SettingsRegistry.all.map(\.key)
    XCTAssertEqual(Set(keys).count, SettingsRegistry.all.count, "key は全項目で一意")
  }

  // MARK: - descriptor(_:) 逆引き

  func testDescriptorLookupReturnsMatchingID() {
    for id in SettingID.allCases {
      XCTAssertEqual(SettingsRegistry.descriptor(id).id, id)
    }
  }

  // MARK: - DefaultedSettingKey の既定（EffectiveSettings が解決する SSOT）

  /// 既定つき項目は defaultValue が非 nil、unset 意味の項目（fontFamily/defaultAgent）は nil。
  func testDefaultValuePresenceMatchesKeyKind() {
    for id in [
      SettingID.fontSize, .backgroundOpacity, .backgroundBlur, .cursorStyleBlink, .theme,
      .emojiFont, .agentStateIcons, .devFeaturesEnabled,
    ] {
      XCTAssertNotNil(SettingsRegistry.descriptor(id).defaultValue(), "\(id) は既定を持つ")
    }
    XCTAssertNil(SettingsRegistry.descriptor(.fontFamily).defaultValue(), "fontFamily は既定なし")
    XCTAssertNil(SettingsRegistry.descriptor(.defaultAgent).defaultValue(), "defaultAgent は既定なし")
    XCTAssertNil(
      SettingsRegistry.descriptor(.tabTitleFontFamily).defaultValue(),
      "tabTitleFontFamily は既定なし（未設定＝システム等幅 11pt）")
  }

  /// 既定値は現行の値（fontSize 12・opacity 95・blur true・blink true・theme auto・icons 空・
  /// devFeatures はチャネル由来 = dev で on・release で off）。
  func testDefaultValues() {
    XCTAssertEqual(SettingsRegistry.descriptor(.fontSize).defaultValue(), .int(12))
    XCTAssertEqual(SettingsRegistry.descriptor(.backgroundOpacity).defaultValue(), .int(95))
    XCTAssertEqual(SettingsRegistry.descriptor(.backgroundBlur).defaultValue(), .bool(true))
    XCTAssertEqual(SettingsRegistry.descriptor(.cursorStyleBlink).defaultValue(), .bool(true))
    XCTAssertEqual(SettingsRegistry.descriptor(.theme).defaultValue(), .string("auto"))
    XCTAssertEqual(SettingsRegistry.descriptor(.emojiFont).defaultValue(), .string("noto"))
    XCTAssertEqual(SettingsRegistry.descriptor(.agentStateIcons).defaultValue(), .stringMap([:]))
    XCTAssertEqual(
      SettingsRegistry.descriptor(.devFeaturesEnabled).defaultValue(), .bool(isDevBuild),
      "既定はチャネル由来（dev=on / release=off）。リテラルで固定すると出荷構成 -DORBE_RELEASE で落ちる")
  }

  // MARK: - guiConf 橋渡し（実効設定の raw を読む・未設定は行を出さない）

  func testFontSizeGuiConfEmitsLineOrNil() {
    let d = SettingsRegistry.descriptor(.fontSize)
    XCTAssertEqual(d.guiConf?(eff { $0[SettingKeys.fontSize] = 14 }), "font-size = 14")
    XCTAssertNil(d.guiConf?(eff()), "fontSize 未設定は行を出さない")
  }

  func testFontFamilyGuiConfEmitsLineOrNil() {
    let d = SettingsRegistry.descriptor(.fontFamily)
    XCTAssertEqual(
      d.guiConf?(eff { $0[SettingKeys.fontFamily] = "Menlo" }),
      "font-family = \"\"\nfont-family = Menlo\nfont-family = JuliaMono")
    XCTAssertNil(d.guiConf?(eff()), "fontFamily 未設定は行を出さない")
  }

  func testThemeGuiConfEmitsConstantLineAlways() {
    let d = SettingsRegistry.descriptor(.theme)
    let line = "theme = light:OrbeLight,dark:OrbeDark"
    XCTAssertEqual(d.guiConf?(eff()), line, "未設定（Auto）でも常時 emit")
    XCTAssertEqual(d.guiConf?(eff { $0[SettingKeys.theme] = .dark }), line, "値非依存")
    XCTAssertEqual(d.guiConf?(eff { $0[SettingKeys.theme] = .light }), line, "値非依存")
  }

  /// emoji-font は theme 同様、未設定でも実効既定（noto）の font-codepoint-map 行を常時 emit する
  /// （単一出所化。JuliaMono 横取り防止が gui.conf 不在時に消えないため）。
  func testEmojiFontGuiConfEmitsMapLineAlways() {
    let d = SettingsRegistry.descriptor(.emojiFont)
    let notoLine = "font-codepoint-map = \(EmojiPresentationRanges.confValue)=Noto Color Emoji"
    XCTAssertEqual(d.guiConf?(eff()), notoLine, "未設定でも実効既定 noto の行を emit")
    XCTAssertEqual(d.guiConf?(eff { $0[SettingKeys.emojiFont] = .noto }), notoLine)
    XCTAssertEqual(
      d.guiConf?(eff { $0[SettingKeys.emojiFont] = .apple }),
      "font-codepoint-map = \(SettingsRegistry.appleEmojiConfValue)=Apple Color Emoji",
      "apple は JuliaMono 横取り 60 点集合を Apple Color Emoji へ map（維持必須）")
  }

  func testDefaultAgentHasNoGuiConf() {
    XCTAssertNil(SettingsRegistry.descriptor(.defaultAgent).guiConf, "agent は gui.conf に出さない")
  }

  func testTabTitleFontFamilyHasNoGuiConf() {
    XCTAssertNil(
      SettingsRegistry.descriptor(.tabTitleFontFamily).guiConf,
      "tab-title-font-family は gui.conf に出さない（chrome 専用・resolver 直配信）")
  }

  func testDevFeaturesEnabledHasNoGuiConf() {
    XCTAssertNil(
      SettingsRegistry.descriptor(.devFeaturesEnabled).guiConf, "dev-features は gui.conf に出さない")
  }

  func testBackgroundOpacityGuiConfEmitsLineOrNil() {
    let d = SettingsRegistry.descriptor(.backgroundOpacity)
    XCTAssertEqual(
      d.guiConf?(eff { $0[SettingKeys.backgroundOpacity] = 90 }), "background-opacity = 0.90")
    XCTAssertEqual(
      d.guiConf?(eff { $0[SettingKeys.backgroundOpacity] = 87 }), "background-opacity = 0.87",
      "端数も 2 桁固定")
    XCTAssertNil(d.guiConf?(eff()), "backgroundOpacity 未設定は行を出さない")
  }

  func testCursorStyleBlinkGuiConfEmitsLineOrNil() {
    let d = SettingsRegistry.descriptor(.cursorStyleBlink)
    XCTAssertEqual(
      d.guiConf?(eff { $0[SettingKeys.cursorStyleBlink] = true }), "cursor-style-blink = true")
    XCTAssertNil(d.guiConf?(eff()), "cursorStyleBlink 未設定は行を出さない")
  }

  func testBackgroundBlurGuiConfEmitsLineOrNil() {
    let d = SettingsRegistry.descriptor(.backgroundBlur)
    XCTAssertEqual(
      d.guiConf?(eff { $0[SettingKeys.backgroundBlur] = true }), "background-blur = true")
    XCTAssertNil(d.guiConf?(eff()), "backgroundBlur 未設定は行を出さない")
  }

  // MARK: - domain と activation の整合

  /// fontSize/backgroundOpacity は stepper＋intRange、値域は宣言 1 箇所が持つ。
  func testStepperItemsHaveIntRangeDomain() {
    let fs = SettingsRegistry.stepperDomain(.fontSize)
    XCTAssertEqual(fs.range, 6...72)
    XCTAssertEqual(fs.step, 1)
    XCTAssertEqual(fs.unit, "pt")
    let bo = SettingsRegistry.stepperDomain(.backgroundOpacity)
    XCTAssertEqual(bo.range, 20...100)
    XCTAssertEqual(bo.unit, "%")
    for id in [SettingID.fontSize, .backgroundOpacity] {
      XCTAssertEqual(SettingsRegistry.descriptor(id).activation, .stepper)
    }
  }

  /// toggle 項目は activation=toggle かつ domain=toggle。
  func testToggleItemsHaveToggleDomainAndActivation() {
    for id in [SettingID.backgroundBlur, .cursorStyleBlink, .devFeaturesEnabled] {
      XCTAssertEqual(SettingsRegistry.descriptor(id).activation, .toggle)
      guard case .toggle = SettingsRegistry.descriptor(id).domain else {
        return XCTFail("\(id) の domain は toggle")
      }
    }
  }

  /// domain の typeName は control config_list の type 提示と一致。
  func testDomainTypeNames() {
    XCTAssertEqual(SettingsRegistry.descriptor(.fontSize).domain.typeName, "int")
    XCTAssertEqual(SettingsRegistry.descriptor(.backgroundBlur).domain.typeName, "bool")
    XCTAssertEqual(SettingsRegistry.descriptor(.theme).domain.typeName, "enum")
    XCTAssertEqual(SettingsRegistry.descriptor(.agentStateIcons).domain.typeName, "map")
  }

  // MARK: - isDrillIn（stepper/toggle は潜らない・drillIn は潜る）

  func testIsDrillInFlags() {
    for id in [
      SettingID.fontSize, .backgroundOpacity, .backgroundBlur, .cursorStyleBlink,
      .devFeaturesEnabled,
    ] {
      XCTAssertFalse(SettingsRegistry.descriptor(id).isDrillIn, "stepper/toggle（\(id)）は潜らない")
    }
    for id in [
      SettingID.fontFamily, .tabTitleFontFamily, .emojiFont, .theme, .defaultAgent,
      .agentStateIcons,
    ] {
      XCTAssertTrue(SettingsRegistry.descriptor(id).isDrillIn, "\(id) は drillIn")
    }
  }

  /// activation と domain の整合を `all` 走査で固定する（項目追加時の誤宣言を test 時に捕捉する不変条件）。
  /// stepper→intRange / toggle→toggle / drillIn→enumeration|stringMap。ここが緑でないと runtime で
  /// stepperDomain の preconditionFailure・toggle の bool 変換失敗を招く。
  func testActivationAndDomainAgreeForEverySetting() {
    for d in SettingsRegistry.all {
      switch d.activation {
      case .stepper:
        guard case .intRange = d.domain else {
          return XCTFail("\(d.id): activation=stepper は domain=intRange 必須（実際: \(d.domain))")
        }
      case .toggle:
        guard case .toggle = d.domain else {
          return XCTFail("\(d.id): activation=toggle は domain=toggle 必須（実際: \(d.domain))")
        }
      case .drillIn:
        switch d.domain {
        case .enumeration, .stringMap: break
        default:
          return XCTFail("\(d.id): activation=drillIn は domain=enumeration|stringMap 必須")
        }
      }
    }
  }
}
