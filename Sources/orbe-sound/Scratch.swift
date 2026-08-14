import Foundation
import OrbeSound

/// ad-hoc 音・デモ音の置き場。**ここを 1 行編集 → `swift build --product orbe-sound` →
/// `orbe-sound board` 再生成 → ブラウザをリロード、が制作ループの本体**（人間側の聴き比べは
/// board が担う。1 音だけなら `orbe-sound play <name> -` でも聴ける）。
/// エントリは (名前, SoundProgram)。名前はカタログ 12 案と重ならないこと（resolve はカタログ名を優先する）。
/// `trimDB` は board で並べたときの音量整合（カタログと同じ基準）——音を変えたら board の
/// `loud` 表示が他と揃うよう測り直す。揃っていないと、聴き比べの判断が音の性格でなく音量差で決まる。
enum Scratch {
  static let entries: [(name: String, program: SoundProgram)] = [
    demoSignal, demoBloom, demoAfterglow,
  ]

  /// デモ 1「合図」: デチューンした sawtooth の 2 声ユニゾン × 五度上行 + フィードバックディレイ。
  /// 既存 12 案に無い要素 = sawtooth の明るさ・ユニゾンの厚み・ディレイの空間。
  private static let demoSignal: (name: String, program: SoundProgram) = (
    "demo-signal",
    SoundProgram(
      components: [
        // 第一音（A5）: ±7 セントの 2 声。lowpass で角を丸める。
        .tone(
          ToneSpec(
            frequency: 880, detuneCents: -7, start: 0, duration: 0.10, waveform: .sawtooth,
            gain: 0.09, lowpass: 3800)),
        .tone(
          ToneSpec(
            frequency: 880, detuneCents: 7, start: 0, duration: 0.10, waveform: .sawtooth,
            gain: 0.09, lowpass: 3800)),
        // 第二音（E6）: 少し長く、ディレイのテールへ渡す。
        .tone(
          ToneSpec(
            frequency: 1318.5, detuneCents: -6, start: 0.12, duration: 0.22, waveform: .sawtooth,
            gain: 0.10, lowpass: 4200)),
        .tone(
          ToneSpec(
            frequency: 1318.5, detuneCents: 6, start: 0.12, duration: 0.22, waveform: .sawtooth,
            gain: 0.10, lowpass: 4200)),
      ],
      effects: [.delay(time: 0.17, feedback: 0.45, damping: 3200, mix: 0.5)],
      duration: 1.5, trimDB: 4.7)
  )

  /// デモ 2「灯り」: ADSR + lowpass の柔らかい和音（sawtooth をローパスで暖める）。
  /// 既存 12 案に無い要素 = サステインを保つ ADSR の腰と、フィルタで作るパッドの質感。
  private static let demoBloom: (name: String, program: SoundProgram) = (
    "demo-bloom",
    SoundProgram(
      components: [261.63, 392.0, 659.25].enumerated().map { voice, frequency in
        .tone(
          ToneSpec(
            frequency: frequency, detuneCents: Double(voice - 1) * 5, start: 0, duration: 0.85,
            waveform: .sawtooth, gain: 0.05,
            envelope: .adsr(attack: 0.05, decay: 0.35, sustain: 0.45, release: 0.45),
            lowpass: 1800))
      }, trimDB: 1.9)
  )

  /// デモ 3「残光」: FM インデックスのエンベロープで開いて閉じる鐘 + トレモロの余韻 + ディレイ。
  /// 既存 12 案に無い要素 = インデックスの時間変化そのものと、gainLFO の揺れ。
  private static let demoAfterglow: (name: String, program: SoundProgram) = (
    "demo-afterglow",
    SoundProgram(
      components: [
        .fm(
          FMSpec(
            frequency: 660, start: 0, duration: 1.5, ratio: 1.4,
            index: .sweep(from: 6, to: 0.05, endFraction: 0.35), gain: 0.11,
            gainLFO: LFO(rate: 5.5, depth: 0.35))),
        // 低いオクターブの sine が余韻の芯を支える。
        .tone(
          ToneSpec(
            frequency: 330, start: 0.02, duration: 1.2, gain: 0.05,
            envelope: .percussive(attack: 0.03))),
      ],
      effects: [.delay(time: 0.28, feedback: 0.35, damping: 2400, mix: 0.3)],
      duration: 2.1, trimDB: 0.6)
  )
}
