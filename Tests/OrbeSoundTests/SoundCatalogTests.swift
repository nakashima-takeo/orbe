import XCTest

@testable import OrbeSound

/// 12 案 × 2 イベントの定義と合成結果の健全性。L1 純ロジック・決定論（音は出さない）。
final class SoundCatalogTests: XCTestCase {
  private let sampleRate = 48000.0

  /// 全案・全イベントが定義されている（案を足して定義を忘れたら落ちる）。
  func testEveryFamilyDefinesBothEvents() {
    XCTAssertEqual(NotificationSound.allCases.count, 12)
    for family in NotificationSound.allCases {
      for event in AgentSoundEvent.allCases {
        XCTAssertFalse(
          SoundCatalog.program(family, event).components.isEmpty, "\(family) の \(event) が未定義")
      }
    }
  }

  /// 部品はすべて 0 秒以降に始まり、必ず長さを持つ。
  func testComponentsAreWellFormed() {
    for family in NotificationSound.allCases {
      for event in AgentSoundEvent.allCases {
        for component in SoundCatalog.program(family, event).components {
          XCTAssertGreaterThanOrEqual(component.start, 0, "\(family)/\(event)")
          XCTAssertGreaterThan(component.end, component.start, "\(family)/\(event)")
        }
      }
    }
  }

  /// 音の全長は 0.05〜2.2 秒に収まり、長い方の 2 案は定義から導かれる長さに固定する
  /// （エフェクト無しの案では、最後の部品の発音が終わる時刻）。
  func testDurations() {
    for family in NotificationSound.allCases {
      for event in AgentSoundEvent.allCases {
        let duration = SoundCatalog.duration(family, event)
        XCTAssertGreaterThan(duration, 0.05, "\(family)/\(event)")
        XCTAssertLessThanOrEqual(duration, 2.2, "\(family)/\(event)")
      }
    }
    XCTAssertEqual(SoundCatalog.duration(.deep, .done), 2.05, accuracy: 1e-9)
    XCTAssertEqual(SoundCatalog.duration(.emblem, .done), 2.07, accuracy: 1e-9, "最長")
  }

  /// 12 案 × 2 イベントが**互いに違う音**になる（`program` の手書き switch は誤配線しても
  /// コンパイラが黙るので、配線の同一性をここで機械検証する。レンダリングは要らない）。
  func testEveryFamilyAndEventProducesADistinctSound() {
    var signatures: Set<SoundProgram> = []
    for family in NotificationSound.allCases {
      for event in AgentSoundEvent.allCases {
        signatures.insert(SoundCatalog.program(family, event))
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

  /// 同じ入力からは常に同じ波形（ノイズを含む案も固定シードで再現する）。
  func testRenderIsDeterministic() {
    for family in [NotificationSound.wood, .air, .piano] {  // ノイズを含む 3 案
      let first = SoundRenderer.render(
        family: family, event: .waiting, volume: 70, sampleRate: sampleRate)
      let second = SoundRenderer.render(
        family: family, event: .waiting, volume: 70, sampleRate: sampleRate)
      XCTAssertEqual(first, second, "\(family) の合成が決定論でない")
    }
  }

  /// 音量は合成の入力（コンプレッサの**手前**）。小さくすれば必ず小さくなり、かつ縮み方は線形でない
  /// ——音量を再生側ボリュームや事前生成音源へ移すと厳密に 0.2 倍になるので、そこで落ちる。
  func testVolumeIsAppliedBeforeTheCompressor() {
    let loud = SoundRenderer.render(
      family: .glass, event: .done, volume: 100, sampleRate: sampleRate)
    let quiet = SoundRenderer.render(
      family: .glass, event: .done, volume: 20, sampleRate: sampleRate)
    XCTAssertEqual(loud.count, quiet.count)
    let loudPeak = loud.map { abs($0) }.max() ?? 0
    let quietPeak = quiet.map { abs($0) }.max() ?? 0
    XCTAssertLessThan(quietPeak, loudPeak)
    XCTAssertGreaterThan(
      quietPeak, loudPeak * 0.2 * 1.02, "コンプレッサの後段なら厳密に 0.2 倍になる")
  }

  /// ラウドネス整合: 全 24 音の RMS(dBFS) が帯域内に収まる（音量 70・48 kHz。帯域は実測分布
  /// -36.4〜-21.3 dB に前後の余白を足した -39〜-19 dB）。案を作り直すときはこの帯域が
  /// 「他の案と並べて音量の違和感が出ない」ことの客観的な物差しになる——外れたら音の gain を
  /// 調整するか、分布ごと動かす意図があるならこの帯域を引き直す。
  func testLoudnessOfEverySoundStaysWithinTheBand() {
    for family in NotificationSound.allCases {
      for event in AgentSoundEvent.allCases {
        let samples = SoundRenderer.render(
          family: family, event: event, volume: 70, sampleRate: sampleRate)
        let rms = SoundAnalysis.rmsDB(samples)
        XCTAssertGreaterThan(rms, -39, "\(family)/\(event) が静かすぎる (\(rms) dBFS)")
        XCTAssertLessThan(rms, -19, "\(family)/\(event) が大きすぎる (\(rms) dBFS)")
      }
    }
  }

  /// サンプルレートが変わっても同じ長さの音になる（biquad 係数もレートへ追従する）。
  func testRenderFollowsSampleRate() {
    let at44k = SoundRenderer.render(family: .pulse, event: .done, volume: 70, sampleRate: 44100)
    let at48k = SoundRenderer.render(family: .pulse, event: .done, volume: 70, sampleRate: 48000)
    XCTAssertEqual(Double(at44k.count) / 44100, Double(at48k.count) / 48000, accuracy: 0.001)
  }
}
