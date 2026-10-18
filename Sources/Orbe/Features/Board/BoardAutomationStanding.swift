import Foundation

/// 自動化 1 つの立ち位置——どれかの部品が走っているか・止めているか・最新の部品の回の区分——を 1 回だけ導いた値。並びの群・点の色・右端の種類は
/// すべてここから読む（同じ判定が並び・点・文・色に散ると、優先順位が 1 か所だけずれる）。自動化そのものは持たない。
struct BoardAutomationStanding: Equatable, Identifiable {
  let id: Int
  let name: String
  let paused: Bool
  let running: Bool
  /// `now` から見て次に予定で回る時刻。止めていれば nil。
  let next: Date?
  /// 最新の回の区分。まだ回っていなければ nil。
  let last: BoardRunTone?

  /// 並びの群（この順に並ぶ）。走っているかは効かない——走り出すたびに行が跳ねないため。
  enum Group: Comparable {
    case failing
    case active
    case paused
  }

  var group: Group {
    if paused { return .paused }
    return last == .failed ? .failing : .active
  }

  /// 右端に出す 1 つ。走っている ＞ 止めている ＞ 前回の結果、の順に決まる。
  enum Mark: Equatable {
    case running
    case paused
    case neverRan
    case ran(BoardRunTone)
  }

  var mark: Mark {
    if running { return .running }
    if paused { return .paused }
    return last.map(Mark.ran) ?? .neverRan
  }
}

extension BoardAutomationStanding {
  init(_ automation: Automation, runner: AutomationRunner, now: Date) {
    self.init(
      id: automation.id, name: automation.name, paused: automation.paused,
      running: runner.isRunning(automation.id), next: runner.nextRunAt(automation, now: now),
      last: automation.runs.first.map { BoardAutomationSummary.tone($0.run) })
  }
}
