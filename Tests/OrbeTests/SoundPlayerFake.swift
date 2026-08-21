import Foundation
import OrbeSound

@testable import Orbe

/// 通知音の再生層のフェイク。「何が何回鳴ったか」だけを記録し、実際には音を出さない。
/// 隔離ハーネス（`TestIsolation.beginCase`）が既定の再生層としてこれを差し、
/// 鳴らす判断を測るテストは自分のインスタンスを観測する。
final class SoundPlayerFake: AgentSoundPlaying {
  struct Played: Equatable {
    let source: ResolvedSource
    let event: AgentSoundEvent
    let volume: Int

    /// 合成音の 1 件（既存の呼び出しをそのままの読みやすさで残すための糖衣）。
    static func synth(_ family: NotificationSound, event: AgentSoundEvent, volume: Int) -> Played {
      Played(source: .synth(family), event: event, volume: volume)
    }
  }

  private(set) var played: [Played] = []
  private(set) var stopCount = 0

  func play(_ source: ResolvedSource, event: AgentSoundEvent, volume: Int) {
    played.append(Played(source: source, event: event, volume: volume))
  }

  func stopPreview() { stopCount += 1 }
}
