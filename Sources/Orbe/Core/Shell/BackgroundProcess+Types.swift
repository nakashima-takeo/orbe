import Foundation

extension BackgroundProcess {
  struct Spec {
    var executable: String
    /// argv[1...]。
    var arguments: [String]
    var environment: [String: String]
    var directory: String
    var stdin: Data?
    var elapsedLimit: TimeInterval
    var idleLimit: TimeInterval?
    var stdout: Stdout
    var stderr: Capture
  }

  /// 標準出力の扱い。
  enum Stdout {
    /// 上限まで貯める。
    case collect(Capture)
    /// 1 行ずつ渡し、貯めない。`maxLength` を超えた行は渡さずに捨て、`Outcome.droppedLines` に数える。
    /// `onLine` が終わり方（出力量の上限・止めた）を返したら、それで打ち切る。nil なら続ける。呼ばれるのは裏の直列キュー。
    case lines(maxLength: Int, onLine: (Data) -> Ending?)
  }

  /// 貯める出力の上限。`overflowStops` が偽なら、超えた分を捨てて走らせ続ける。
  struct Capture {
    var limit: Int
    var overflowStops: Bool
  }

  struct Captured: Equatable {
    var data = Data()
    var truncated = false
  }

  enum Limit: Equatable, CaseIterable {
    case elapsed
    case idle
    case output
  }

  enum Ending: Equatable {
    case exited(Int32)
    case signaled(Int32)
    case limited(Limit)
    case stopped
    /// `posix_spawn` の失敗（errno）。
    case launchFailed(Int32)
  }

  struct Outcome {
    let ending: Ending
    let stdout: Captured
    let stderr: Captured
    let droppedLines: Int
    /// 起こしてから終わるまでの長さ（秒）。経過時間の上限と同じ、スリープ中を数えない時計で測る。起こさなかったなら 0。
    let elapsed: TimeInterval
  }
}
