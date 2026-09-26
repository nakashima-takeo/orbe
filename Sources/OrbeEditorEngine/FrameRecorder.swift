import Foundation
import os

/// 面ごとの記録係（描画スレッドだけ）。各コマの描画の CPU 時間・画面に出た時刻（present）・そのコマに初めて入った指の
/// 出来事の時刻・drawable の大きさの食い違いを取り、ジェスチャーごとに要約を 1 行、OS のログ（カテゴリ `editor-frames`）へ
/// 出す。常に動くので軽く保つ——溜めるのはジェスチャー 1 つぶんだけ。
///
/// - 出来事→present: 指の出来事の時刻から、その量が初めて入ったコマが画面に出た時刻まで。
/// - 落ちたコマ: 位置が動いている間に、続く 2 つの present の間隔が 1.5 刻みを越えたもの。割合は越えた分の時間の合計を
///   経過時間で割ったもの（ms/秒）。
final class FrameRecorder {
  /// 描いたコマ 1 つ。
  struct Drawn {
    var frame: Int
    /// 画面に出る予定の時刻。
    var target: Double
    /// 描画の CPU 時間（秒）。
    var cpu: Double
    /// 命令を出し終えた時刻。
    var committed: Double
    /// このコマで初めて入った指の出来事の時刻。
    var events: [Double]
    /// 前のコマから位置が動いたか。
    var moving: Bool
    var gesture: Int
    /// drawable の大きさが view の大きさ × 倍率と食い違っていた（伸びた絵の兆し）。
    var mismatch: Bool
  }

  /// ジェスチャー 1 つぶんの記録。
  struct Gesture: Equatable, Sendable {
    var id: Int
    var latencies: [Double] = []
    /// 位置が動いたコマが画面に出た時刻。
    var presents: [Double] = []
    var mismatches = 0
  }

  /// 要約（ms）。
  struct Summary: Equatable, Sendable, CustomStringConvertible {
    var latencyMedian: Double
    var latencyP95: Double
    var latencyMax: Double
    var frames: Int
    var drops: Int
    var droppedPerSecond: Double
    var mismatches: Int

    var description: String {
      String(
        format:
          "event→present median %.1fms p95 %.1fms max %.1fms / frames %d / dropped %d %.1fms/s"
          + " / size mismatches %d",
        latencyMedian, latencyP95, latencyMax, frames, drops, droppedPerSecond, mismatches)
    }
  }

  /// 計測（テスト）が読む通算の値。
  struct Totals: Sendable {
    /// 描画の CPU 時間（秒）。
    var cpu: [Double] = []
    /// 描くものがあったのに、上限（画面に出ていないコマ・GPU の空き）で飛ばした回数。前のコマが画面に出るのが
    /// 遅れたときに起きる。
    var skipped = 0
    /// 描画スレッドが、画面に出る予定の刻みの 1ms 前までに命令を出し終えられなかったコマの数（描画スレッド自身の遅れ）。
    var lateCommits = 0
    /// 命令は間に合ったのに、予定の刻みより後に画面に出たコマの数（GPU や画面の合成の混み）。
    var latePresents = 0
    /// 締めたジェスチャーの記録。
    var gestures: [Gesture] = []
  }

  /// 命令を出し終えるべき、画面に出る予定の刻みより前の余裕（GPU が描く分）。
  static let commitMargin = 0.001

  private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.orbe", category: "editor-frames")

  private var pending: [Int: Drawn] = [:]
  private var current: Gesture?
  /// 刻みの長さ（秒）。
  var period = 1.0 / 120
  /// 通算の値を溜めるか（計測のときだけ）。
  var keepsTotals = false
  private(set) var totals = Totals()

  /// 描いたコマの数（止めてから締めるまでに次のコマが来たかを見る）。
  private(set) var drawnCount = 0

  func drew(_ drawn: Drawn) {
    drawnCount += 1
    if keepsTotals { totals.cpu.append(drawn.cpu) }
    if let current, current.id != drawn.gesture { flush() }
    if drawn.moving || !drawn.events.isEmpty {
      if current == nil { current = Gesture(id: drawn.gesture) }
      if drawn.mismatch { current?.mismatches += 1 }
    }
    pending[drawn.frame] = drawn
  }

  func resetTotals() { totals = Totals() }

  func skipped() {
    if keepsTotals { totals.skipped += 1 }
  }

  /// コマが画面に出た（`time` が nil なら出ずに捨てられた）。
  func presented(frame: Int, time: Double?) {
    guard let record = pending.removeValue(forKey: frame), let time else { return }
    if keepsTotals {
      if record.committed > record.target - Self.commitMargin {
        totals.lateCommits += 1
      } else if time > record.target + period / 2 {
        totals.latePresents += 1
      }
    }
    guard current?.id == record.gesture else { return }
    current?.latencies.append(contentsOf: record.events.map { time - $0 })
    if record.moving { current?.presents.append(time) }
  }

  /// 今のジェスチャーを締めて要約を出す。
  func flush() {
    guard let gesture = current else { return }
    current = nil
    if keepsTotals { totals.gestures.append(gesture) }
    guard let summary = Self.summary(gesture, period: period) else { return }
    Self.log.log("gesture \(gesture.id): \(summary.description, privacy: .public)")
  }

  /// 今のジェスチャーの番号（締めていなければ）。
  var gesture: Int? { current?.id }

  static func summary(_ gesture: Gesture, period: Double) -> Summary? {
    guard !gesture.latencies.isEmpty || gesture.presents.count > 1 else { return nil }
    let latencies = gesture.latencies.sorted()
    func quantile(_ q: Double) -> Double {
      latencies.isEmpty
        ? 0 : latencies[min(latencies.count - 1, Int(Double(latencies.count) * q))] * 1000
    }
    let presents = gesture.presents.sorted()
    var drops = 0
    var dropped = 0.0
    for (a, b) in zip(presents, presents.dropFirst()) where b - a > 1.5 * period {
      drops += 1
      dropped += b - a - period
    }
    let span = (presents.last ?? 0) - (presents.first ?? 0)
    return Summary(
      latencyMedian: quantile(0.5), latencyP95: quantile(0.95),
      latencyMax: (latencies.last ?? 0) * 1000, frames: presents.count, drops: drops,
      droppedPerSecond: span > 0 ? dropped / span * 1000 : 0, mismatches: gesture.mismatches)
  }
}
