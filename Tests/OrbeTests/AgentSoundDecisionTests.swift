import OrbeSound
import XCTest

@testable import Orbe

/// 「鳴らすか・何を鳴らすか」の判断（純関数）。状態 × 選択 × イベント × 同一化トグル ×
/// カスタム音源の有無 × オンオフ × 音量の全組み合わせを固定する。
final class AgentSoundDecisionTests: OrbeTestCase {

  private func source(_ file: String) -> CustomSoundSource {
    CustomSoundSource(file: file, name: file, duration: 1.5)
  }

  private func settings(
    sound: AgentSoundChoice? = nil, volume: Int? = nil, enabled: Bool? = nil,
    customDone: CustomSoundSource? = nil, customWaiting: CustomSoundSource? = nil,
    waitingSameAsDone: Bool? = nil
  ) -> EffectiveSettings {
    var layer = SettingsLayer()
    layer[SettingKeys.notificationSound] = sound
    layer[SettingKeys.notificationSoundVolume] = volume
    layer[SettingKeys.notificationSoundEnabled] = enabled
    layer[SettingKeys.notificationSoundCustomDone] = customDone
    layer[SettingKeys.notificationSoundCustomWaiting] = customWaiting
    layer[SettingKeys.notificationSoundCustomWaitingSameAsDone] = waitingSameAsDone
    return EffectiveSettings(layer)
  }

  /// waiting / done だけが鳴る。working / idle / clear・未知の状態は鳴らさない。
  func testOnlyWaitingAndDoneSound() {
    XCTAssertEqual(AgentSoundDecision.plan(state: "done", settings: settings())?.event, .done)
    XCTAssertEqual(AgentSoundDecision.plan(state: "waiting", settings: settings())?.event, .waiting)
    for state in ["working", "idle", "clear", "dormant", ""] {
      XCTAssertNil(AgentSoundDecision.plan(state: state, settings: settings()), state)
    }
  }

  /// 未設定は既定（案は `NotificationSound.default`・音量 90・オン）で鳴る。
  func testDefaultsSound() {
    let plan = AgentSoundDecision.plan(state: "done", settings: settings())
    XCTAssertEqual(
      plan,
      AgentSoundDecision.Plan(source: .synth(NotificationSound.default), event: .done, volume: 90))
  }

  /// 通知音オフは、状態にかかわらず鳴らさない。
  func testDisabledNeverSounds() {
    for state in ["done", "waiting"] {
      XCTAssertNil(AgentSoundDecision.plan(state: state, settings: settings(enabled: false)), state)
    }
  }

  /// 音量は「鳴らすか」を左右しない——下限 5% でも鳴り、黙らせるのはオン/オフだけ。
  func testVolumeNeverSuppressesSound() {
    for volume in [5, 100] {
      XCTAssertEqual(
        AgentSoundDecision.plan(state: "done", settings: settings(volume: volume))?.volume, volume)
    }
  }

  /// 設定した案と音量がそのまま計画に載る。
  func testPlanCarriesConfiguredFamilyAndVolume() {
    let plan = AgentSoundDecision.plan(
      state: "waiting", settings: settings(sound: .preset(.steel), volume: 35, enabled: true))
    XCTAssertEqual(
      plan, AgentSoundDecision.Plan(source: .synth(.steel), event: .waiting, volume: 35))
  }

  /// 全案 × 全イベント × オンオフ × 音量（下限/既定/上限）の総当たり。
  func testExhaustiveMatrix() {
    for family in NotificationSound.allCases {
      for event in AgentSoundEvent.allCases {
        for enabled in [true, false] {
          for volume in [5, 70, 100] {
            let plan = AgentSoundDecision.plan(
              state: event.rawValue,
              settings: settings(sound: .preset(family), volume: volume, enabled: enabled))
            if enabled {
              XCTAssertEqual(
                plan,
                AgentSoundDecision.Plan(source: .synth(family), event: event, volume: volume))
            } else {
              XCTAssertNil(plan, "\(family)/\(event)/enabled=\(enabled)/volume=\(volume)")
            }
          }
        }
      }
    }
  }

  // MARK: - カスタム音源の解決マトリクス

  /// `custom` × event × 同一化トグル × 設定の有無の総当たり。
  /// トグルが左右するのは**どのファイルを引くか**だけで、未設定時の落とし先は常に同 event。
  func testCustomSourceMatrix() {
    let done = source("done.wav")
    let waiting = source("waiting.wav")
    for event in AgentSoundEvent.allCases {
      for sameAsDone in [true, false] {
        for hasDone in [true, false] {
          for hasWaiting in [true, false] {
            let plan = AgentSoundDecision.plan(
              state: event.rawValue,
              settings: settings(
                sound: .custom, customDone: hasDone ? done : nil,
                customWaiting: hasWaiting ? waiting : nil, waitingSameAsDone: sameAsDone))
            let usesDoneFile = event == .done || sameAsDone
            let available = usesDoneFile ? hasDone : hasWaiting
            let expected: ResolvedSource =
              available
              ? .imported(file: usesDoneFile ? done.file : waiting.file)
              : .synth(NotificationSound.default)
            XCTAssertEqual(
              plan?.source, expected,
              "\(event)/same=\(sameAsDone)/done=\(hasDone)/waiting=\(hasWaiting)")
          }
        }
      }
    }
  }

  /// フォールバックは常に**同 event**。トグル on で done が未設定でも、waiting の報告は
  /// 紋章の **waiting** 音で鳴る（「done を代わりに鳴らす」ではない）。
  func testFallbackAlwaysStaysOnTheSameEvent() {
    let plan = AgentSoundDecision.plan(
      state: "waiting",
      settings: settings(sound: .custom, customWaiting: source("w.wav"), waitingSameAsDone: true))
    XCTAssertEqual(plan?.source, .synth(NotificationSound.default))
    XCTAssertEqual(plan?.event, .waiting, "落ちても event は waiting のまま")
  }

  /// 同一化トグルの既定はオン（waiting は done の音源を使う）。
  func testWaitingSameAsDoneDefaultsOn() {
    let plan = AgentSoundDecision.plan(
      state: "waiting",
      settings: settings(
        sound: .custom, customDone: source("done.wav"), customWaiting: source("waiting.wav")))
    XCTAssertEqual(plan?.source, .imported(file: "done.wav"), "既定オンなので done の音源")
  }

  /// カスタム選択でも「鳴らない」の担体はオン/オフだけ（未設定でも鳴る・オフなら鳴らない）。
  func testCustomStillObeysTheOnOffSwitch() {
    XCTAssertNotNil(AgentSoundDecision.plan(state: "done", settings: settings(sound: .custom)))
    XCTAssertNil(
      AgentSoundDecision.plan(state: "done", settings: settings(sound: .custom, enabled: false)))
  }
}
