import Foundation

extension GitRunner {
  struct Output {
    let status: Int32
    let stdout: Data
    let stderr: Data
    /// 終わり方。`status` の値で見分けさせない（`-1` は起動失敗にも打ち切りにも使う）。
    let ending: Ending
    /// git の終了を観測できたか。打ち切った後に「作りかけの成果物が残っているか」で成否を
    /// 読み替える呼び出し側は、その判定が意味を持つ前提としてこれを見る。
    let exited: Bool

    var timedOut: Bool { ending == .timedOut }
    var stdoutText: String { String(bytes: stdout, encoding: .utf8) ?? "" }
    var stderrText: String { String(bytes: stderr, encoding: .utf8) ?? "" }
    var isSuccess: Bool { status == 0 }
  }

  /// 実行の終わり方。
  enum Ending: Equatable {
    /// git が自分で終わった（成否は `status`）。
    case completed
    /// 無出力が続いて打ち切った。
    case timedOut
    /// 止めた（`Handle.cancel`）。起こす前に止めたなら git は起きていない。
    case cancelled
    /// 起動できなかった（`stderr` にその理由）。
    case launchFailed
  }
}
