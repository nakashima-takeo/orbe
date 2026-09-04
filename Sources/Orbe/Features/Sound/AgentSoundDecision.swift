import Foundation
import OrbeSound

/// 実際に鳴らす音源。合成する案か、取り込み済みのファイルか。再生層はこの 2 つだけを知る。
enum ResolvedSource: Equatable, Hashable {
  case synth(NotificationSound)
  /// `sounds/` 配下の相対名（`CustomSoundStore` が実体を解決する）。
  case imported(file: String)

  /// 合成音か（＝有限の閉じた値域を持つか）。再生層のキャッシュがこれで載せる/載せないを決める。
  var isSynth: Bool {
    if case .synth = self { return true }
    return false
  }
}

/// 「鳴らすか・何を鳴らすか」の判断（純関数）。設定だけを見るのでテストで全組み合わせを機械検証できる。
///
/// 「見ているタブか」だけはここに入れない——`WindowController` の窓とタブの状態に依存するため、
/// 通知を組む側（`WindowController.agentNotification(for:)`）が `visibleTab` 判定で先に弾く。
enum AgentSoundDecision {
  struct Plan: Equatable {
    let source: ResolvedSource
    let event: AgentSoundEvent
    let volume: Int
  }

  /// waiting / done 以外の状態・通知音オフは鳴らさない（nil）。
  /// 「鳴らない」の担体はオン/オフただ 1 つ——音量は 5% を下限に持ち、無音になる値を取らない。
  static func plan(state: String, settings: EffectiveSettings) -> Plan? {
    guard let event = AgentSoundEvent(rawValue: state) else { return nil }
    guard settings[SettingKeys.notificationSoundEnabled] else { return nil }
    return Plan(
      source: source(event: event, settings: settings), event: event,
      volume: settings[SettingKeys.notificationSoundVolume])
  }

  /// 実効の選択に従って音源を解決する（実通知も設定パレットの試聴も、この 1 経路を通る）。
  static func source(event: AgentSoundEvent, settings: EffectiveSettings) -> ResolvedSource {
    source(choice: settings[SettingKeys.notificationSound], event: event, settings: settings)
  }

  /// 選択を明示して解決する。設定パレットが「カスタム行を選んだら何が鳴るか」を、値を書く前に
  /// 試聴するために使う——聴くことと決めることを分けたまま、耳に届く音は確定後と同じにする。
  ///
  /// カスタム音源が未設定のときは**紋章の同 event 音**へ落ちる。トグルが on でも done が未設定なら
  /// 落ちる先は紋章の waiting 音で、フォールバックは常に同 event ——「鳴らない」の担体は
  /// オン/オフの 1 つだけ、という原則をここでも崩さない。
  static func source(
    choice: AgentSoundChoice, event: AgentSoundEvent, settings: EffectiveSettings
  ) -> ResolvedSource {
    switch choice {
    case .preset(let sound):
      return .synth(sound)
    case .custom:
      guard let custom = customSource(event: event, settings: settings) else {
        return .synth(.default)
      }
      return .imported(file: custom.file)
    }
  }

  /// その event に効くカスタム音源（トグル on の waiting は done の音源を使う）。
  /// トグルが左右するのは**どのファイルを引くか**だけで、フォールバック先の event は動かさない。
  static func customSource(event: AgentSoundEvent, settings: EffectiveSettings)
    -> CustomSoundSource?
  {
    if event == .done || settings[SettingKeys.notificationSoundCustomWaitingSameAsDone] {
      return settings[SettingKeys.notificationSoundCustomDone]
    }
    return settings[SettingKeys.notificationSoundCustomWaiting]
  }
}
