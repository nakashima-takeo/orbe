import Foundation
import OrbeSound

/// ad-hoc 音・デモ音の置き場。**ここを 1 行編集 → `swift build --product orbe-sound` →
/// `orbe-sound play <name> -` が制作ループの本体**。エントリは (名前, SoundProgram)。
/// 名前はカタログ 12 案と重ならないこと（resolve はカタログ名を優先する）。
enum Scratch {
  static let entries: [(name: String, program: SoundProgram)] = [
    // 書き味の見本（自由に書き換えてよい）: 五度のデチューン 2 声 + 短いディレイ。
    (
      "sketch",
      SoundProgram(
        components: [
          .tone(ToneSpec(frequency: 880, start: 0, duration: 0.4, gain: 0.12)),
          .tone(ToneSpec(frequency: 880, detuneCents: 8, start: 0, duration: 0.4, gain: 0.10)),
        ],
        effects: [.delay(time: 0.16, feedback: 0.4, damping: 3500, mix: 0.4)],
        duration: 1.4)
    )
  ]
}
