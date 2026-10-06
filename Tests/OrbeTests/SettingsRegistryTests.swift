import OrbeSound
import XCTest

@testable import Orbe

/// 設定レジストリ（SSOT）の宣言的契約と不変条件の検証。App 層・純ロジック。
/// key の安定と一意・`rootOrder`（表示順）・domain と activation の整合を固定する。
final class SettingsRegistryTests: OrbeTestCase {

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
      SettingsRegistry.descriptor(.menuBarNotificationDuration).key, "menubar-notification-duration"
    )
    XCTAssertEqual(SettingsRegistry.confKey(.fontSize), "font-size", "confKey は descriptor.key を引く")
    let keys = SettingsRegistry.all.map(\.key)
    XCTAssertEqual(Set(keys).count, SettingsRegistry.all.count, "key は全項目で一意")
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
    let duration = SettingsRegistry.stepperDomain(.menuBarNotificationDuration)
    XCTAssertEqual(duration.range, 5...180)
    XCTAssertEqual(duration.step, 5)
    XCTAssertEqual(duration.unit, "s")
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
      SettingID.fontSize, .backgroundOpacity, .notificationSoundVolume,
      .menuBarNotificationDuration,
    ] {
      XCTAssertEqual(SettingsRegistry.descriptor(id).activation, .stepper)
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
