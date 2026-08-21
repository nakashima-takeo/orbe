import OrbeSound

/// `NotificationSound` / `AgentSoundEvent`（OrbeSound の純 DSP 語彙）をアプリの語彙へ橋渡しする層。
/// ラベルと状態グリフは L10n / `AgentStateIcon` に依存するため OrbeSound 側には置けない。
/// 設定値への変換は持たない——設定が持つのは案とカスタムを合わせた `AgentSoundChoice` で、
/// 案だけを直に設定値へできると `custom` を素通しする key を書けてしまう。
extension NotificationSound {
  /// 設定パレット行・descriptor display の表示ラベル（`EmojiFontMode.labelKey` 前例＝案自身が名乗る）。
  /// 並行配列で位置結合するとラベル取り違えが黙って通るため、写像はここ 1 箇所に持つ。
  var labelKey: L10nKey {
    switch self {
    case .glass: return .soundGlass
    case .pulse: return .soundPulse
    case .wood: return .soundWood
    case .air: return .soundAir
    case .emblem: return .soundEmblem
    case .reply: return .soundReply
    case .bounce: return .soundBounce
    case .arcade: return .soundArcade
    case .steel: return .soundSteel
    case .piano: return .soundPiano
    case .whistle: return .soundWhistle
    case .deep: return .soundDeep
    }
  }
}

extension AgentSoundEvent {
  /// 試聴対象のセグメント表示に使うラベル（状態名の語彙をそのまま共有する）。
  var labelKey: L10nKey {
    switch self {
    case .done: return .agentStateDone
    case .waiting: return .agentStateWaiting
    }
  }

  /// 状態の語彙への橋（セグメントのグリフと試聴 EQ の色が共有する 1 経路。状態色を二重定義しない）。
  var glyphKind: AgentStateIcon.Kind {
    switch self {
    case .done: return .done
    case .waiting: return .waiting
    }
  }
}
