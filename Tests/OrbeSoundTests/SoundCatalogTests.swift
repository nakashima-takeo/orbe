import XCTest

@testable import OrbeSound

/// 12 案 × 2 イベントの定義と合成結果の健全性。L1 純ロジック・決定論（音は出さない）。
final class SoundCatalogTests: XCTestCase {
  private let sampleRate = 48000.0

  /// 音の全長は 0.05〜2.2 秒に収まり、部品型ごとに 1 案を定義から導かれる長さに固定する
  /// （エフェクト無しの案では、最後の部品の発音が終わる時刻）。全長は試聴 EQ の消灯タイミング
  /// でもあるので、エンベロープの既定を動かして黙って伸び縮みさせない——tone 系（deep / emblem）に
  /// 加えて glide 系（reply）も釘を打つ。glide の既定 `.gate` は release ぶん duration より伸びる。
  func testDurations() {
    for family in NotificationSound.allCases {
      for event in AgentSoundEvent.allCases {
        let duration = SoundCatalog.duration(family, event)
        XCTAssertGreaterThan(duration, 0.05, "\(family)/\(event)")
        XCTAssertLessThanOrEqual(duration, 2.2, "\(family)/\(event)")
      }
    }
    XCTAssertEqual(SoundCatalog.duration(.deep, .done), 2.00, accuracy: 1e-9)
    XCTAssertEqual(SoundCatalog.duration(.emblem, .done), 2.02, accuracy: 1e-9, "最長")
    XCTAssertEqual(
      SoundCatalog.duration(.reply, .done), 0.73, accuracy: 1e-9, "glide は release ぶん伸びる")
  }

  /// 12 案 × 2 イベントが**互いに違う音**になる（`program` の手書き switch は誤配線しても
  /// コンパイラが黙るので、配線の同一性をここで機械検証する。レンダリングは要らない）。
  /// 署名からトリムは外す——トリムは「どう鳴るか」であって「どの音か」ではなく、音ごとに違う値が
  /// 署名を必ず散らすので、含めると誤配線が丸ごと隠れる。
  func testEveryFamilyAndEventProducesADistinctSound() {
    var signatures: Set<SoundProgram> = []
    for family in NotificationSound.allCases {
      for event in AgentSoundEvent.allCases {
        var signature = SoundCatalog.program(family, event)
        signature.trimDB = 0
        signatures.insert(signature)
      }
    }
    XCTAssertEqual(signatures.count, 24, "案 × イベントの配線が重複している")
  }

  /// 合成結果は有限・非空・非クリップで、長さは全長 × サンプルレート。
  /// assert は音ごとに 1 回だけ——サンプル単位で撃つと、退行時に百万件の failure 記録で CI が止まる。
  func testRenderedWaveformsAreFiniteAndUnclipped() {
    for family in NotificationSound.allCases {
      for event in AgentSoundEvent.allCases {
        let samples = SoundRenderer.render(
          family: family, event: event, volume: 100, sampleRate: sampleRate)
        let expected = Int((SoundCatalog.duration(family, event) * sampleRate).rounded(.up))
        XCTAssertEqual(samples.count, expected, "\(family)/\(event) の長さ")
        var peak: Float = 0
        var finite = true
        for sample in samples {
          if !sample.isFinite { finite = false }
          peak = max(peak, abs(sample))
        }
        XCTAssertTrue(finite, "\(family)/\(event) に NaN / Inf")
        XCTAssertGreaterThan(peak, 0.001, "\(family)/\(event) が無音")
        XCTAssertLessThanOrEqual(peak, 1, "\(family)/\(event) がクリップ")
      }
    }
  }

  /// 音量は合成の入力（コンプレッサの**手前**）。小さくすれば必ず小さくなり、かつ縮み方は
  /// マッピングの比そのものにならない——音量を再生側ボリュームや事前生成音源へ移すと
  /// 厳密に `level(forVolume: 20)` 倍になるので、そこで落ちる。
  func testVolumeIsAppliedBeforeTheCompressor() {
    let loud = SoundRenderer.render(
      family: .glass, event: .done, volume: 100, sampleRate: sampleRate)
    let quiet = SoundRenderer.render(
      family: .glass, event: .done, volume: 20, sampleRate: sampleRate)
    XCTAssertEqual(loud.count, quiet.count)
    let loudPeak = loud.map { abs($0) }.max() ?? 0
    let quietPeak = quiet.map { abs($0) }.max() ?? 0
    let ratio = Float(SoundRenderer.level(forVolume: 20))
    XCTAssertLessThan(quietPeak, loudPeak)
    XCTAssertGreaterThan(
      quietPeak, loudPeak * ratio * 1.02, "コンプレッサの後段なら厳密にこの比になる")
  }

  /// ラウドネス整合: 全 24 音の最大短時間 RMS（300 ms 窓・既定音量 90・48 kHz）が整合目標
  /// （`SoundCatalog.loudnessTargetDB`）へ揃う（実測残差 ±0.3 dB に余白を足して ±0.8 dB）。
  /// 目標を定数で見るのは、取り込むカスタム音源（`SoundImportTests`）と**同じ 1 点**を向いていることを
  /// ここでも縛るため——リテラルで書くと、目標を動かしたときにカスタム側だけが追随して両方緑になる。
  /// これが「他の案と並べて
  /// 音量の違和感が出ない」ことの客観的な物差し——音の定義を変えて外れたら、`SoundCatalog` の
  /// トリム表をその音だけ測り直して目標へ戻す。
  func testLoudnessOfEverySoundStaysAligned() {
    for family in NotificationSound.allCases {
      for event in AgentSoundEvent.allCases {
        let samples = SoundRenderer.render(
          family: family, event: event, volume: SoundRenderer.defaultVolume,
          sampleRate: sampleRate)
        let loud = SoundAnalysis.maxShortTermRMSDB(samples, sampleRate: sampleRate)
        XCTAssertEqual(
          loud, SoundCatalog.loudnessTargetDB, accuracy: 0.8,
          "\(family)/\(event) の音量が揃っていない (\(loud) dBFS)")
      }
    }
  }
}
