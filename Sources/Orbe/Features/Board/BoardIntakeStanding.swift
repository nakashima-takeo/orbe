import Foundation

/// 自動追加 1 つの立ち位置——走っているか・止めているか・前回の結果——を 1 回だけ導いた値。並びの群・点の色・右端の文と色は
/// すべてここから読む（同じ判定が並び・点・文・色に散ると、優先順位が 1 か所だけずれる）。
struct BoardIntakeStanding: Equatable, Identifiable {
  let intake: Intake
  let running: Bool
  /// 次に予定で回る時刻。止めていれば nil。
  let next: Date?

  init(_ intake: Intake, runner: IntakeRunner) {
    self.intake = intake
    running = runner.isRunning(intake.id)
    next = runner.nextRunAt(intake)
  }

  var id: Int { intake.id }

  /// 並びの群（この順に並ぶ）。走っているかは効かない——走り出すたびに行が跳ねないため。
  enum Group: Comparable {
    case failing
    case active
    case paused
  }

  var group: Group {
    if intake.paused { return .paused }
    return intake.runs.first?.failure == nil ? .active : .failing
  }

  /// 右端に出す 1 つ。走っている ＞ 止めている ＞ 前回の結果、の順に決まる。
  enum Mark: Equatable {
    case running
    case paused
    case neverRan
    case failed(IntakeRun)
    case ran(IntakeRun)
  }

  var mark: Mark {
    if running { return .running }
    if intake.paused { return .paused }
    guard let last = intake.runs.first else { return .neverRan }
    return last.failure == nil ? .ran(last) : .failed(last)
  }
}
