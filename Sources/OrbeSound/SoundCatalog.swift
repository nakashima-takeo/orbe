import Foundation

/// 12 案 × 2 イベント（完了 / 入力待ち）の合成定義。ここは「何をどう鳴らすか」の宣言だけで、
/// 部品の語彙は `SoundComponent`、波形の作り方は `SoundSynth`、実際の合成は `SoundRenderer` が担う。
public enum SoundCatalog {
  /// 案 × イベントの完全な定義（部品列 + エフェクト列 + 全長 + ラウドネストリム）。
  public static func program(_ family: NotificationSound, _ event: AgentSoundEvent) -> SoundProgram
  {
    var program = definition(family, event)
    if let trim = trims[family] {
      program.trimDB += event == .done ? trim.done : trim.waiting
    }
    return program
  }

  /// ラウドネス整合の実測トリム（dB）。基準は最大短時間 RMS（300 ms 窓・既定音量 90・48 kHz。
  /// 300 ms に満たない音は全長で測るので、長さを変えると読みが動く）で、全 24 音を
  /// カタログ中央値 -24.0 dBFS へ合わせた値。音の定義を変えたらその音だけ測り直す
  /// （`orbe-sound board` で WAV を出し、300 ms 窓の最大 RMS と目標の差分を足し引きする）。
  /// 測るのは必ず既定音量で——音量はコンプレッサの手前なので圧縮の深さが音ごとに違い、測定点を
  /// 動かすと読みは平行移動せず整合もわずかに崩れる（24 音のばらつき幅は実測で音量 70 が 0.38 dB、
  /// 90 が 0.46 dB、100 が 0.84 dB と上端ほど広がる）。
  private static let trims: [NotificationSound: (done: Double, waiting: Double)] = [
    .glass: (done: -1.7, waiting: 1.6),
    .pulse: (done: 7.8, waiting: 9.0),
    .wood: (done: 0.2, waiting: 1.5),
    .air: (done: 0.3, waiting: 6.4),
    .emblem: (done: -1.5, waiting: 5.0),
    .reply: (done: -5.9, waiting: -5.0),
    .bounce: (done: -3.3, waiting: 1.8),
    .arcade: (done: 8.7, waiting: 10.5),
    .steel: (done: -1.4, waiting: -1.1),
    .piano: (done: -0.7, waiting: 3.3),
    .whistle: (done: -0.7, waiting: -2.6),
    .deep: (done: -0.5, waiting: -0.2),
  ]

  private static func definition(_ family: NotificationSound, _ event: AgentSoundEvent)
    -> SoundProgram
  {
    switch family {
    case .glass: return glass(event)
    case .pulse: return pulse(event)
    case .wood: return wood(event)
    case .air: return air(event)
    case .emblem: return emblem(event)
    case .reply: return reply(event)
    case .bounce: return bounce(event)
    case .arcade: return arcade(event)
    case .steel: return steel(event)
    case .piano: return piano(event)
    case .whistle: return whistle(event)
    case .deep: return deep(event)
    }
  }

  /// 音の全長（テール込み。試聴 EQ の消灯タイミングが読む）。
  public static func duration(_ family: NotificationSound, _ event: AgentSoundEvent) -> Double {
    program(family, event).duration
  }

  // MARK: - 硝子 / 電紫 / 木肌 / 気配

  /// 澄んだガラスの倍音。完了は五度上行の二音、入力待ちは同音の控えめな二打。
  private static func glass(_ event: AgentSoundEvent) -> SoundProgram {
    switch event {
    case .done:
      return SoundProgram(
        components: bell(1318.5, at: 0, duration: 0.9, gain: 0.13)
          + bell(1975.5, at: 0.10, duration: 1.1, gain: 0.11))
    case .waiting:
      return SoundProgram(
        components: bell(987.8, at: 0, duration: 0.6, gain: 0.13)
          + bell(987.8, at: 0.28, duration: 0.8, gain: 0.11))
    }
  }

  /// 端末らしい電子パルス。完了は上行の二連、入力待ちは同音の三連（1 打ごとに 0.01 ずつ減衰）。
  private static func pulse(_ event: AgentSoundEvent) -> SoundProgram {
    switch event {
    case .done:
      return SoundProgram(components: [
        .tone(ToneSpec(frequency: 880, start: 0, duration: 0.07, waveform: .triangle, gain: 0.14)),
        .tone(
          ToneSpec(frequency: 1318.5, start: 0.09, duration: 0.12, waveform: .triangle, gain: 0.14)),
      ])
    case .waiting:
      return SoundProgram(
        components: (0..<3).map { i in
          .tone(
            ToneSpec(
              frequency: 659.3, start: Double(i) * 0.14, duration: 0.07, waveform: .triangle,
              gain: 0.15 - Double(i) * 0.01))
        })
    }
  }

  /// マリンバ調の柔らかい打音。完了は五度上行の二打、入力待ちは静かな同音の二打。
  private static func wood(_ event: AgentSoundEvent) -> SoundProgram {
    switch event {
    case .done:
      return SoundProgram(
        components: knock(784, at: 0, duration: 0.45, gain: 0.14)
          + knock(1174.7, at: 0.12, duration: 0.55, gain: 0.13))
    case .waiting:
      return SoundProgram(
        components: knock(523.3, at: 0, duration: 0.4, gain: 0.14)
          + knock(523.3, at: 0.22, duration: 0.4, gain: 0.12))
    }
  }

  /// 息づかいのようなノイズと淡い和音。完了は和音がふわりと灯り、入力待ちは息に澄んだ音が二度乗る。
  private static func air(_ event: AgentSoundEvent) -> SoundProgram {
    switch event {
    case .done:
      return SoundProgram(components: [
        .tone(
          ToneSpec(
            frequency: 523.25, start: 0, duration: 0.9, gain: 0.10,
            envelope: .percussive(attack: 0.12))),
        .tone(
          ToneSpec(
            frequency: 659.25, start: 0.05, duration: 1.0, gain: 0.09,
            envelope: .percussive(attack: 0.15))),
        .noise(
          NoiseSpec(
            start: 0, duration: 0.7, gain: 0.035, kind: .highpass, cutoff: .constant(5000),
            envelope: .percussive(attack: 0.2))),
      ])
    case .waiting:
      return SoundProgram(
        components: [0.0, 0.5].flatMap { t -> [SoundComponent] in
          let first = t == 0
          return [
            .noise(
              NoiseSpec(
                start: t, duration: 0.45, gain: first ? 0.10 : 0.08, kind: .bandpass,
                cutoff: .sweep(from: 900, to: 1400), q: 2, envelope: .percussive(attack: 0.12))),
            .tone(
              ToneSpec(
                frequency: 1046.5, start: t, duration: first ? 0.5 : 0.55,
                gain: first ? 0.09 : 0.07, envelope: .percussive(attack: 0.08))),
          ]
        })
    }
  }

  // MARK: - 紋章 / 返事 / 弾み / 遊技

  /// 「オー・ベ」の二拍を模した和音 → 鐘のモチーフ。入力待ちはその前半だけを静かに。
  private static func emblem(_ event: AgentSoundEvent) -> SoundProgram {
    switch event {
    case .done:
      return SoundProgram(
        components: [
          .tone(
            ToneSpec(
              frequency: 392, start: 0, duration: 0.5, waveform: .triangle, gain: 0.10,
              envelope: .percussive(attack: 0.02))),
          .tone(
            ToneSpec(
              frequency: 587.3, start: 0, duration: 0.5, waveform: .triangle, gain: 0.08,
              envelope: .percussive(attack: 0.02))),
        ] + bell(784, at: 0.30, duration: 1.5, gain: 0.12)
          + bell(1568, at: 0.42, duration: 1.6, gain: 0.06))
    case .waiting:
      return SoundProgram(components: [
        .tone(
          ToneSpec(
            frequency: 392, start: 0, duration: 0.7, waveform: .triangle, gain: 0.11,
            envelope: .percussive(attack: 0.05))),
        .tone(
          ToneSpec(
            frequency: 587.3, start: 0.35, duration: 0.9, waveform: .triangle, gain: 0.10,
            envelope: .percussive(attack: 0.05))),
      ])
    }
  }

  /// 声のような抑揚。完了は弾んで上がる「できた！」、入力待ちは語尾が上がる「ん〜？」。
  private static func reply(_ event: AgentSoundEvent) -> SoundProgram {
    switch event {
    case .done:
      return SoundProgram(components: [
        .glide(GlideSpec(from: 330, to: 660, start: 0, duration: 0.16, gain: 0.13)),
        .glide(
          GlideSpec(
            from: 495, to: 1050, start: 0.18, duration: 0.4, gain: 0.14, overshoot: 1.12,
            pitchLFO: LFO(rate: 7, depth: 6))),
      ])
    case .waiting:
      return SoundProgram(components: [
        .glide(
          GlideSpec(
            from: 440, to: 640, start: 0, duration: 0.55, gain: 0.12, overshoot: 1.06,
            pitchLFO: LFO(rate: 5.5, depth: 8)))
      ])
    }
  }

  /// ゴムまりの跳ね。完了はぐっと沈んでから跳び上がり、入力待ちは小さく二度はずむ。
  private static func bounce(_ event: AgentSoundEvent) -> SoundProgram {
    switch event {
    case .done:
      return SoundProgram(
        components: [
          .glide(
            GlideSpec(
              from: 240, to: 240, start: 0, duration: 0.08, waveform: .triangle, gain: 0.13)),
          .glide(
            GlideSpec(
              from: 260, to: 1180, start: 0.10, duration: 0.28, waveform: .triangle, gain: 0.14,
              overshoot: 1.25)),
        ] + bell(2093, at: 0.34, duration: 0.5, gain: 0.06))
    case .waiting:
      return SoundProgram(
        components: [(0.0, 0.12), (0.30, 0.10)].map { start, gain in
          .glide(
            GlideSpec(
              from: 300, to: 520, start: start, duration: 0.14, waveform: .triangle, gain: gain,
              overshoot: 1.2))
        })
    }
  }

  /// レトロゲームの矩形波。完了は駆け上がるコイン音、入力待ちは高めの二連ブリップ ×2 回。
  private static func arcade(_ event: AgentSoundEvent) -> SoundProgram {
    func blip(_ f: Double, _ t: Double, _ d: Double, _ g: Double, _ lowpass: Double)
      -> SoundComponent
    {
      .tone(
        ToneSpec(
          frequency: f, start: t, duration: d, waveform: .square, gain: g, lowpass: lowpass))
    }
    switch event {
    case .done:
      return SoundProgram(components: [
        blip(523.25, 0.00, 0.055, 0.05, 3500), blip(659.25, 0.06, 0.055, 0.05, 3500),
        blip(784, 0.12, 0.055, 0.05, 3500), blip(1046.5, 0.18, 0.055, 0.05, 3500),
        blip(1318.5, 0.26, 0.2, 0.055, 3500),
      ])
    case .waiting:
      return SoundProgram(components: [
        blip(523.25, 0.00, 0.08, 0.06, 3000), blip(698.5, 0.14, 0.08, 0.06, 3000),
        blip(523.25, 0.42, 0.08, 0.055, 3000), blip(698.5, 0.56, 0.18, 0.055, 3000),
      ])
    }
  }

  // MARK: - 鋼 / 洋琴 / 口笛 / 深層

  /// FM 合成の金属打音。完了は金属の二打が響き合い、入力待ちはまろやかな鉄琴を二度。
  private static func steel(_ event: AgentSoundEvent) -> SoundProgram {
    switch event {
    case .done:
      return SoundProgram(components: [
        .fm(
          FMSpec(
            frequency: 440, start: 0, duration: 1.3, ratio: 1.4,
            index: .sweep(from: 5, to: 0.02, endFraction: 0.5), gain: 0.11)),
        .fm(
          FMSpec(
            frequency: 660, start: 0.16, duration: 1.6, ratio: 1.4,
            index: .sweep(from: 4, to: 0.02, endFraction: 0.5), gain: 0.10)),
      ])
    case .waiting:
      return SoundProgram(
        components: [(0.0, 1.0, 0.15), (0.45, 1.1, 0.13)].map { start, duration, gain in
          .fm(
            FMSpec(
              frequency: 440, start: start, duration: duration, ratio: 2,
              index: .sweep(from: 3.5, to: 0.02, endFraction: 0.35), gain: gain))
        })
    }
  }

  /// ピアノの打鍵。完了は長三和音を駆け上がる三音、入力待ちは同じ鍵を静かに二度。
  private static func piano(_ event: AgentSoundEvent) -> SoundProgram {
    switch event {
    case .done:
      return SoundProgram(
        components: piano(523.25, at: 0, duration: 1.2, gain: 0.10)
          + piano(783.99, at: 0.14, duration: 1.4, gain: 0.09)
          + piano(1046.5, at: 0.28, duration: 1.8, gain: 0.09))
    case .waiting:
      return SoundProgram(
        components: piano(659.25, at: 0, duration: 1.0, gain: 0.10)
          + piano(659.25, at: 0.4, duration: 1.2, gain: 0.08))
    }
  }

  /// 人の口笛。完了は「ピュイ・ピュウ」の二声、入力待ちは語尾が上がる呼びかけ。
  private static func whistle(_ event: AgentSoundEvent) -> SoundProgram {
    switch event {
    case .done:
      return SoundProgram(components: [
        .glide(
          GlideSpec(
            from: 1046.5, to: 1568, start: 0, duration: 0.28, gain: 0.09,
            pitchLFO: LFO(rate: 6, depth: 10))),
        .glide(
          GlideSpec(
            from: 1760, to: 1318.5, start: 0.34, duration: 0.35, gain: 0.08,
            pitchLFO: LFO(rate: 6, depth: 12))),
      ])
    case .waiting:
      return SoundProgram(components: [
        .glide(
          GlideSpec(
            from: 1174.7, to: 1568, start: 0, duration: 0.5, gain: 0.09,
            pitchLFO: LFO(rate: 5, depth: 14)))
      ])
    }
  }

  /// 柔らかいパッドの和音がゆっくり灯って消える。入力待ちはパッドの上で鐘が二度呼ぶ。
  private static func deep(_ event: AgentSoundEvent) -> SoundProgram {
    switch event {
    case .done:
      return SoundProgram(
        components: [261.6, 392, 659.3].map {
          .tone(
            ToneSpec(
              frequency: $0, start: 0, duration: 2.0, gain: 0.06,
              envelope: .percussive(attack: 0.3)))
        } + bell(1318.5, at: 0.5, duration: 1.4, gain: 0.05))
    case .waiting:
      return SoundProgram(
        components: [
          .tone(
            ToneSpec(
              frequency: 349.2, start: 0, duration: 1.2, gain: 0.08,
              envelope: .percussive(attack: 0.2))),
          .tone(
            ToneSpec(
              frequency: 440, start: 0, duration: 1.2, gain: 0.06,
              envelope: .percussive(attack: 0.2))),
        ] + bell(1046.5, at: 0.10, duration: 0.9, gain: 0.09)
          + bell(1046.5, at: 0.55, duration: 1.1, gain: 0.07))
    }
  }
}
