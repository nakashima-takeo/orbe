import Foundation

@testable import Orbe

/// 通知音の再生層のフェイク。「何が何回鳴ったか」だけを記録し、実際には音を出さない。
/// 隔離ハーネス（`TestIsolation.beginCase`）が既定の再生層としてこれを差し、
/// 鳴らす判断を測るテストは自分のインスタンスを観測する。
final class SoundPlayerFake: AgentSoundPlaying {
  struct Played: Equatable {
    let family: NotificationSound
    let event: AgentSoundEvent
    let volume: Int
  }

  private(set) var played: [Played] = []
  private(set) var stopCount = 0

  func play(_ family: NotificationSound, event: AgentSoundEvent, volume: Int) {
    played.append(Played(family: family, event: event, volume: volume))
  }

  func stopPreview() { stopCount += 1 }
}
