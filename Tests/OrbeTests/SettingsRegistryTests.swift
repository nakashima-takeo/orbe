import OrbeSound
import XCTest

@testable import Orbe

/// 設定レジストリ（SSOT）の宣言的契約と不変条件の検証。App 層・純ロジック。
/// `all`（gui.conf 正準順）と `rootOrder`（表示順）の 2 順序・key 一意・domain と activation の整合・
/// guiConf 橋渡し・DefaultedSettingKey の既定を固定する。
final class SettingsRegistryTests: OrbeTestCase {

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
        .worktreeDir, .notificationSound, .notificationSoundVolume,
        .notificationSoundEnabled, .notificationSoundCustomDone, .notificationSoundCustomWaiting,
        .notificationSoundCustomWaitingSameAsDone, .menuBarNoticeDwell,
      ])
  }

  /// `rootOrder` は設定パレット root の表示順。
  func testRootOrderIsDisplayOrder() {
    XCTAssertEqual(
      SettingsRegistry.rootOrder.map(\.id),
      [
        .fontSize, .backgroundOpacity, .backgroundBlur, .cursorStyleBlink, .theme,
        .defaultAgent, .fontFamily, .tabTitleFontFamily, .emojiFont, .agentStateIcons,
        .worktreeDir, .notificationSound, .notificationSoundVolume,
        .notificationSoundEnabled, .menuBarNoticeDwell,
      ])
  }

  /// `all` は SettingID の全 case を過不足なく含む。`rootOrder` はその部分集合で、差は
  /// **root に行を持たない項目の明示リスト**（`nonRootIDs`）とちょうど一致する
  /// ——「rootOrder が全 case を含む」を単に緩めると、行の書き漏れが検出されなくなる。
  func testAllCoversEverySettingIDAndRootOrderIsAllMinusTheNonRootSet() {
    let allIDs = Set(SettingID.allCases)
    XCTAssertEqual(Set(SettingsRegistry.all.map(\.id)), allIDs, "all が全 case を含む")
    XCTAssertEqual(
      SettingsRegistry.nonRootIDs,
      [
        .notificationSoundCustomDone, .notificationSoundCustomWaiting,
        .notificationSoundCustomWaitingSameAsDone,
      ], "root に出さない項目はこの 3 件だけ（カスタム設定サブの中でだけ編集される）")
    XCTAssertEqual(
      Set(SettingsRegistry.rootOrder.map(\.id)), allIDs.subtracting(SettingsRegistry.nonRootIDs),
      "rootOrder は非掲載を除く全 case をちょうど覆う")
    XCTAssertEqual(
      SettingsRegistry.rootOrder.count,
      SettingID.allCases.count - SettingsRegistry.nonRootIDs.count,
      "rootOrder に重複は無い")
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
    XCTAssertEqual(SettingsRegistry.descriptor(.worktreeDir).key, "worktree-dir")
    XCTAssertEqual(SettingsRegistry.descriptor(.notificationSound).key, "notification-sound")
    XCTAssertEqual(
      SettingsRegistry.descriptor(.notificationSoundVolume).key, "notification-sound-volume")
    XCTAssertEqual(
      SettingsRegistry.descriptor(.notificationSoundEnabled).key, "notification-sound-enabled")
    XCTAssertEqual(
      SettingsRegistry.descriptor(.notificationSoundCustomDone).key,
      "notification-sound-custom-done")
    XCTAssertEqual(
      SettingsRegistry.descriptor(.notificationSoundCustomWaiting).key,
      "notification-sound-custom-waiting")
    XCTAssertEqual(
      SettingsRegistry.descriptor(.notificationSoundCustomWaitingSameAsDone).key,
      "notification-sound-custom-waiting-same-as-done")
    XCTAssertEqual(
      SettingsRegistry.descriptor(.menuBarNoticeDwell).key, "menubar-notice-dwell")
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
      .emojiFont, .agentStateIcons, .worktreeDir, .notificationSound,
      .notificationSoundVolume, .notificationSoundEnabled,
      .notificationSoundCustomWaitingSameAsDone, .menuBarNoticeDwell,
    ] {
      XCTAssertNotNil(SettingsRegistry.descriptor(id).defaultValue(), "\(id) は既定を持つ")
    }
    for id in [SettingID.notificationSoundCustomDone, .notificationSoundCustomWaiting] {
      XCTAssertNil(
        SettingsRegistry.descriptor(id).defaultValue(), "\(id) は既定なし（未取り込み＝未設定）")
    }
    XCTAssertNil(SettingsRegistry.descriptor(.fontFamily).defaultValue(), "fontFamily は既定なし")
    XCTAssertNil(SettingsRegistry.descriptor(.defaultAgent).defaultValue(), "defaultAgent は既定なし")
    XCTAssertNil(
      SettingsRegistry.descriptor(.tabTitleFontFamily).defaultValue(),
      "tabTitleFontFamily は既定なし（未設定＝システム等幅 11pt）")
  }

  /// 既定値は現行の値（fontSize 12・opacity 95・blur true・blink true・theme auto・icons 空）。
  func testDefaultValues() {
    XCTAssertEqual(SettingsRegistry.descriptor(.fontSize).defaultValue(), .int(12))
    XCTAssertEqual(SettingsRegistry.descriptor(.backgroundOpacity).defaultValue(), .int(95))
    XCTAssertEqual(SettingsRegistry.descriptor(.backgroundBlur).defaultValue(), .bool(true))
    XCTAssertEqual(SettingsRegistry.descriptor(.cursorStyleBlink).defaultValue(), .bool(true))
    XCTAssertEqual(SettingsRegistry.descriptor(.theme).defaultValue(), .string("auto"))
    XCTAssertEqual(SettingsRegistry.descriptor(.emojiFont).defaultValue(), .string("noto"))
    XCTAssertEqual(SettingsRegistry.descriptor(.agentStateIcons).defaultValue(), .stringMap([:]))
    XCTAssertEqual(
      SettingsRegistry.descriptor(.worktreeDir).defaultValue(),
      .string("{parent}/{repo}-worktrees/{slug}"), "既定は従来のハードコード規則と同一パスに解決するテンプレート")
    XCTAssertEqual(
      SettingsRegistry.descriptor(.notificationSound).defaultValue(),
      AgentSoundChoice.default.settingValue,
      "既定の選択は AgentSoundChoice.default が SSOT（リテラルを 2 箇所に置かない）")
    XCTAssertEqual(
      SettingsRegistry.descriptor(.notificationSound).defaultValue(),
      .string(NotificationSound.default.rawValue), "既定は案（＝紋章）であってカスタムではない")
    XCTAssertEqual(
      SettingsRegistry.descriptor(.notificationSoundCustomWaitingSameAsDone).defaultValue(),
      .bool(true), "waiting 同一化は既定オン")
    XCTAssertEqual(
      SettingsRegistry.descriptor(.notificationSoundVolume).defaultValue(), .int(90),
      "既定の音量は SoundRenderer.defaultVolume が SSOT——dev CLI の --volume 既定も同じ 1 つを見る")
    XCTAssertEqual(
      SettingsRegistry.descriptor(.notificationSoundEnabled).defaultValue(), .bool(true))
    XCTAssertEqual(
      SettingsRegistry.descriptor(.menuBarNoticeDwell).defaultValue(), .int(40),
      "②ピルの既定の滞留は 40 秒——`AttentionStore` は既定を持たず、ここが唯一の出所")
  }

  /// 通知音の 3 件はどれも gui.conf に出さない（libghostty 設定ではない）。
  func testNotificationSoundHasNoGuiConf() {
    for id in [
      SettingID.notificationSound, .notificationSoundVolume, .notificationSoundEnabled,
      .notificationSoundCustomDone, .notificationSoundCustomWaiting,
      .notificationSoundCustomWaitingSameAsDone,
    ] {
      XCTAssertNil(SettingsRegistry.descriptor(id).guiConf, "\(id) は gui.conf に出さない")
    }
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
      "font-family = \"\"\nfont-family = Menlo")
    XCTAssertNil(d.guiConf?(eff()), "fontFamily 未設定は行を出さない")
  }

  func testThemeGuiConfEmitsConstantLineAlways() {
    let d = SettingsRegistry.descriptor(.theme)
    let line = "theme = light:OrbeLight,dark:OrbeDark"
    XCTAssertEqual(d.guiConf?(eff()), line, "未設定（Auto）でも常時 emit")
    XCTAssertEqual(d.guiConf?(eff { $0[SettingKeys.theme] = .dark }), line, "値非依存")
    XCTAssertEqual(d.guiConf?(eff { $0[SettingKeys.theme] = .light }), line, "値非依存")
  }

  /// emoji-font=noto は未設定（実効既定）でも同梱 Noto への map 行を emit する
  /// ——「同梱 Noto のフラット字形で描く」という機能そのものなので、gui.conf 不在時に消えては困る。
  /// apple は行を出さない。libghostty が macOS で Apple Color Emoji を必ず fallback へ挿すので、
  /// 奪う側の font-family を 1 本に絞った今、打ち消しの map は不要（出すと VS16 の扱いを狂わせるだけ）。
  func testEmojiFontGuiConfEmitsNotoMapAndOmitsAppleMap() {
    let d = SettingsRegistry.descriptor(.emojiFont)
    let notoLine = "font-codepoint-map = \(EmojiPresentationRanges.confValue)=Noto Color Emoji"
    XCTAssertEqual(d.guiConf?(eff()), notoLine, "未設定でも実効既定 noto の行を emit")
    XCTAssertEqual(d.guiConf?(eff { $0[SettingKeys.emojiFont] = .noto }), notoLine)
    XCTAssertNil(
      d.guiConf?(eff { $0[SettingKeys.emojiFont] = .apple }),
      "apple は font-codepoint-map 行を出さない（ハードコード fallback の Apple が描く）")
  }

  func testDefaultAgentHasNoGuiConf() {
    XCTAssertNil(SettingsRegistry.descriptor(.defaultAgent).guiConf, "agent は gui.conf に出さない")
  }

  func testTabTitleFontFamilyHasNoGuiConf() {
    XCTAssertNil(
      SettingsRegistry.descriptor(.tabTitleFontFamily).guiConf,
      "tab-title-font-family は gui.conf に出さない（chrome 専用・resolver 直配信）")
  }

  func testWorktreeDirHasNoGuiConf() {
    XCTAssertNil(
      SettingsRegistry.descriptor(.worktreeDir).guiConf,
      "worktree-dir は gui.conf に出さない（Dispatch が実効値を pull する）")
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
    let dwell = SettingsRegistry.stepperDomain(.menuBarNoticeDwell)
    XCTAssertEqual(dwell.range, 5...180)
    XCTAssertEqual(dwell.step, 5)
    XCTAssertEqual(dwell.unit, "s")
    let volume = SettingsRegistry.stepperDomain(.notificationSoundVolume)
    XCTAssertEqual(volume.range, 5...100, "下限 5%——無音は音量でなくオン/オフが担う")
    XCTAssertEqual(volume.step, 5)
    XCTAssertEqual(volume.unit, "%")
    // 音量の値域は `SoundRenderer` の dB 等間隔マッピングの錨でもある（別モジュールなので型では繋がらない）。
    // 下限を動かすと最小音量の実効ゲインが、刻みを動かすと 1 押しの効きが、どちらも黙って変わる。
    XCTAssertEqual(
      SoundRenderer.level(forVolume: volume.range.lowerBound), 0.05, accuracy: 1e-12,
      "値域の下限で合成ゲインが 0.05（-26.02 dB）に落ちる")
    XCTAssertEqual(
      20
        * log10(
          SoundRenderer.level(forVolume: volume.range.lowerBound + volume.step)
            / SoundRenderer.level(forVolume: volume.range.lowerBound)),
      1.3695, accuracy: 1e-4, "1 押しの効きは全域 1.3695 dB")
    for id in [
      SettingID.fontSize, .backgroundOpacity, .notificationSoundVolume, .menuBarNoticeDwell,
    ] {
      XCTAssertEqual(SettingsRegistry.descriptor(id).activation, .stepper)
    }
  }

  /// toggle 項目は activation=toggle かつ domain=toggle。
  func testToggleItemsHaveToggleDomainAndActivation() {
    for id in [
      SettingID.backgroundBlur, .cursorStyleBlink, .notificationSoundEnabled,
      .notificationSoundCustomWaitingSameAsDone,
    ] {
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
    XCTAssertEqual(SettingsRegistry.descriptor(.worktreeDir).domain.typeName, "string")
    XCTAssertEqual(
      SettingsRegistry.descriptor(.notificationSoundCustomDone).domain.typeName, "map")
  }

  /// 通知音の選択は 12 案 ＋ `custom` の閉じた値域（control config_set の membership 検証もここを読む）。
  func testNotificationSoundDomainIncludesCustom() {
    guard case .enumeration(let values) = SettingsRegistry.descriptor(.notificationSound).domain
    else { return XCTFail("notification-sound の domain は enumeration") }
    XCTAssertEqual(values(), NotificationSound.allCases.map(\.rawValue) + ["custom"])
    XCTAssertNil(
      SettingsRegistry.descriptor(.notificationSound).domain.validate("no-such-sound"),
      "値域外は拒否する")
    XCTAssertEqual(
      SettingsRegistry.descriptor(.notificationSound).domain.validate("custom"), .string("custom"))
  }

  // MARK: - isDrillIn（stepper/toggle は潜らない・drillIn は潜る）

  func testIsDrillInFlags() {
    for id in [
      SettingID.fontSize, .backgroundOpacity, .backgroundBlur, .cursorStyleBlink,
      .notificationSoundVolume, .notificationSoundEnabled,
      .notificationSoundCustomWaitingSameAsDone, .menuBarNoticeDwell,
    ] {
      XCTAssertFalse(SettingsRegistry.descriptor(id).isDrillIn, "stepper/toggle（\(id)）は潜らない")
    }
    for id in [
      SettingID.fontFamily, .tabTitleFontFamily, .emojiFont, .theme, .defaultAgent,
      .agentStateIcons, .worktreeDir, .notificationSound, .notificationSoundCustomDone,
      .notificationSoundCustomWaiting,
    ] {
      XCTAssertTrue(SettingsRegistry.descriptor(id).isDrillIn, "\(id) は drillIn")
    }
  }

  /// activation と domain の整合を `all` 走査で固定する（項目追加時の誤宣言を test 時に捕捉する不変条件）。
  /// stepper→intRange / toggle→toggle / drillIn→enumeration|stringMap|pathTemplate。ここが緑でないと
  /// runtime で stepperDomain の preconditionFailure・toggle の bool 変換失敗を招く。
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
        case .enumeration, .stringMap, .pathTemplate: break
        default:
          return XCTFail(
            "\(d.id): activation=drillIn は domain=enumeration|stringMap|pathTemplate 必須")
        }
      }
    }
  }
}
