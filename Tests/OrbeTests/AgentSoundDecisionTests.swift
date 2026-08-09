import XCTest

@testable import Orbe

/// 「鳴らすか・何を鳴らすか」の判断（純関数）。状態 × オンオフ × 音量の全組み合わせを固定する。
final class AgentSoundDecisionTests: OrbeTestCase {

  private func settings(
    sound: NotificationSound? = nil, volume: Int? = nil, enabled: Bool? = nil
  ) -> EffectiveSettings {
    var layer = SettingsLayer()
    layer[SettingKeys.notificationSound] = sound
    layer[SettingKeys.notificationSoundVolume] = volume
    layer[SettingKeys.notificationSoundEnabled] = enabled
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

  /// 未設定は既定（案は `NotificationSound.default`・音量 70・オン）で鳴る。
  func testDefaultsSound() {
    let plan = AgentSoundDecision.plan(state: "done", settings: settings())
    XCTAssertEqual(
      plan, AgentSoundDecision.Plan(family: NotificationSound.default, event: .done, volume: 70))
  }

  /// 通知音オフは、状態にかかわらず鳴らさない。
  func testDisabledNeverSounds() {
    for state in ["done", "waiting"] {
      XCTAssertNil(AgentSoundDecision.plan(state: state, settings: settings(enabled: false)), state)
    }
  }

  /// 音量 0 は鳴らさない（無音の波形を作って再生する意味が無い）。
  func testZeroVolumeNeverSounds() {
    for state in ["done", "waiting"] {
      XCTAssertNil(AgentSoundDecision.plan(state: state, settings: settings(volume: 0)), state)
    }
    XCTAssertNotNil(AgentSoundDecision.plan(state: "done", settings: settings(volume: 5)))
  }

  /// 設定した案と音量がそのまま計画に載る。
  func testPlanCarriesConfiguredFamilyAndVolume() {
    let plan = AgentSoundDecision.plan(
      state: "waiting", settings: settings(sound: .steel, volume: 35, enabled: true))
    XCTAssertEqual(plan, AgentSoundDecision.Plan(family: .steel, event: .waiting, volume: 35))
  }

  /// 全案 × 全イベント × オンオフ × 音量 0 / 非 0 の総当たり。
  func testExhaustiveMatrix() {
    for family in NotificationSound.allCases {
      for event in AgentSoundEvent.allCases {
        for enabled in [true, false] {
          for volume in [0, 70] {
            let plan = AgentSoundDecision.plan(
              state: event.rawValue,
              settings: settings(sound: family, volume: volume, enabled: enabled))
            if enabled && volume > 0 {
              XCTAssertEqual(
                plan, AgentSoundDecision.Plan(family: family, event: event, volume: volume))
            } else {
              XCTAssertNil(plan, "\(family)/\(event)/enabled=\(enabled)/volume=\(volume)")
            }
          }
        }
      }
    }
  }
}
