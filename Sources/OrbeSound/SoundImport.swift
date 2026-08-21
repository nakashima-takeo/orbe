import Foundation

/// 手持ちの音声ファイルを通知音として取り込むときの信号処理（純 DSP・Foundation のみ）。
///
/// 取り込みは「元ファイルへの依存を切る」ための工程で、ここを通った音は 12 案と同じ性質になる
/// ——長さの上限が決まっており、聴感上の音量が全 24 音と揃い、以後は外の世界が変わっても鳴り方が
/// 変わらない。デコードとファイル入出力はアプリ層（`SoundFileImporter`）が持ち、ここは
/// サンプル列 → サンプル列の決定論的な変換だけを担う。
public enum SoundImport {
  /// 取り込む長さの上限（秒）。通知音は「気づかせる」ための音なので、これ以上は鳴らし切らない。
  /// 上限があることで、全長バッファを持つ再生層のメモリも設計から有界になる。
  public static let maxDuration = 10.0

  /// 打ち切ったときに末尾へ掛けるフェード（秒）。曲の途中でぶつ切りにしないため。
  private static let truncationFade = 0.2

  /// 両端に常時掛ける短いフェード（秒）。ゼロクロスで始まらない/終わらないファイルの
  /// プチッというクリックを消す。音の印象を変えない長さに留める。
  private static let declickFade = 0.003

  /// 正規化ゲインの許容誤差（dB）。既存 24 音のラウドネステストの許容（±0.8 dB）より十分細かい。
  private static let gainTolerance = 0.02

  /// 持ち上げる上限（dB）。目標より これ以上下にいる入力は、音ではなく雑音底（録り損ね・
  /// 無音区間だけのファイル）として弾く——上限が無いと 10^90 倍のような意味のないゲインを探しに行く。
  private static let maxNeededGainDB = 60.0

  /// 探索区間の両端に足す余白（dB）。区間は傾きの上下界からちょうど導かれるので、端が答えに
  /// 一致する入力（例: 圧縮域に入らない小音量）では丸め誤差で端がわずかに外れうる。
  private static let searchMarginDB = 6.0

  public struct Processed: Equatable {
    /// 正規化済みのサンプル列（**コンプレッサは掛けていない**——それは再生時のマスタ末尾で、
    /// 合成音とまったく同じ位置に掛かる）。
    public let samples: [Float]
    /// 処理後の実長（秒）。試聴 EQ の点灯時間として設定値へ書き写す。
    public let duration: Double
  }

  /// 取り込めない理由。読めない・デコードできないはアプリ層が判じるので、ここが返すのは
  /// 「音が入っていない」だけ——目標ラウドネスへ届かせられる信号が無い状態。
  public enum Failure: Error, Equatable { case silent }

  /// 打ち切り → デクリック → ラウドネス正規化。同じ入力からは常に同じ結果になる。
  public static func process(_ samples: [Float], sampleRate: Double) throws -> Processed {
    guard sampleRate > 0 else { throw Failure.silent }
    // 非有限値（float32 の WAV/AIFF/CAF は NaN/Inf を表現できる）はここで落とす。1 個でも通すと
    // マスタ末尾のコンプレッサが持つ 1 次の帰還が NaN に固着し、そこから末尾までの全サンプルが
    // NaN のまま出力へ流れる。逆に先頭にあると全窓が NaN 扱いになり、実音のあるファイルが
    // 「音が入っていない」として弾かれる。マスタ末尾は 12 案と共有なので、守るのはこの入口 1 箇所。
    var out = samples.map { $0.isFinite ? $0 : 0 }
    let limit = Int((maxDuration * sampleRate).rounded())
    if out.count > limit {
      out = Array(out[0..<limit])
      fadeOut(&out, seconds: truncationFade, sampleRate: sampleRate)
    }
    declick(&out, sampleRate: sampleRate)
    guard let gain = normalizationGain(out, sampleRate: sampleRate) else { throw Failure.silent }
    return Processed(
      samples: out.map { Float(Double($0) * gain) },
      duration: Double(out.count) / sampleRate)
  }

  // MARK: - フェード

  /// 末尾 `seconds` を直線的に 0 へ落とす（音より長い指定は全長へクランプ）。
  private static func fadeOut(_ samples: inout [Float], seconds: Double, sampleRate: Double) {
    let count = min(samples.count, Int(seconds * sampleRate))
    guard count > 1 else { return }
    let first = samples.count - count
    for i in 0..<count {
      samples[first + i] *= Float(1 - Double(i) / Double(count - 1))
    }
  }

  /// 両端に短いフェードを掛ける。両端の窓が重なる極端に短い音では、それぞれ半分までに抑える。
  private static func declick(_ samples: inout [Float], sampleRate: Double) {
    let count = min(Int(declickFade * sampleRate), samples.count / 2)
    guard count > 1 else { return }
    for i in 0..<count {
      let ramp = Float(Double(i) / Double(count - 1))
      samples[i] *= ramp
      samples[samples.count - 1 - i] *= ramp
    }
  }

  // MARK: - ラウドネス正規化

  /// 「再生時のマスタ末尾（既定音量）を通した後の最大短時間 RMS が `loudnessTargetDB` になる」
  /// 前段ゲイン（線形）。無音・目標へ届かない極小信号は nil。
  ///
  /// コンプレッサの静特性は単調（傾きは `DynamicsCompressor.ratio` の逆数 〜 素通しの 1 の間）なので、
  /// この写像「前段ゲイン dB → 出力 dB」も同じ範囲の傾きを持つ単調関数になり、必要なゲインは
  /// その 2 つの傾きから作った区間に必ず入る。あとは二分探索で詰める。
  ///
  /// 合わせるのは短時間 RMS だけで、振幅の天井は見ない。コンプレッサのアタックより速い立ち上がりは
  /// 素通しするので、クレストの大きい素材はピークが 0 dBFS を数サンプル超えうる（実測で最悪 0.3ms）。
  /// 天井でも抑えると同じ素材が数 dB 静かになり、「取り込んだ音が 12 案と同格に鳴る」というこの工程の
  /// 目的そのものが崩れる——ごく短い歪みより、ラウドネス整合を優先する。
  private static func normalizationGain(_ samples: [Float], sampleRate: Double) -> Double? {
    let target = SoundCatalog.loudnessTargetDB
    let base = measure(samples, gainDB: 0, sampleRate: sampleRate)
    guard base.isFinite else { return nil }  // 無音（全サンプル 0）
    let need = target - base
    // 傾きは 1 以下なので、`need` dB 未満のゲインでは目標へ**絶対に**届かない。上限を超えて
    // 要るということは、鳴っているのが雑音底しかないということ。
    guard need <= maxNeededGainDB else { return nil }
    // 傾き 1（素通し）なら `need` dB、傾きが最小（最大圧縮）なら `ratio · need` dB で目標へ届くので、
    // 答えはこの 2 つが挟む区間の中にある。
    let span = DynamicsCompressor.ratio * need
    var low = min(need, span) - searchMarginDB
    var high = max(need, span) + searchMarginDB
    guard measure(samples, gainDB: low, sampleRate: sampleRate) <= target,
      measure(samples, gainDB: high, sampleRate: sampleRate) >= target
    else { return nil }
    while high - low > gainTolerance {
      let mid = (low + high) / 2
      if measure(samples, gainDB: mid, sampleRate: sampleRate) < target {
        low = mid
      } else {
        high = mid
      }
    }
    return pow(10, ((low + high) / 2) / 20)
  }

  /// 前段ゲインを掛けてマスタ末尾（既定音量）を通したときの最大短時間 RMS（dBFS）。
  private static func measure(_ samples: [Float], gainDB: Double, sampleRate: Double) -> Double {
    let gain = Float(pow(10, gainDB / 20))
    let finalized = SoundRenderer.finalize(
      samples.map { $0 * gain }, volume: SoundRenderer.defaultVolume, sampleRate: sampleRate)
    return SoundAnalysis.maxShortTermRMSDB(finalized, sampleRate: sampleRate)
  }
}
