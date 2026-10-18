import Foundation

/// 自動化 1 つの立ち位置——走っているか・止めているか・最後の回が失敗した部品があるか——を 1 回だけ導いた値。並びの群と名前の
/// 右の状態はここから読む（同じ判定が並び・状態に散ると、優先順位が 1 か所だけずれる）。状態（実行中・停止中）と前回の結果
/// （成否の印）は混ぜない。自動化そのものは持たない。
struct BoardAutomationStanding: Equatable, Identifiable {
  let id: Int
  let name: String
  let paused: Bool
  /// どれかの部品が走っているか、流している途中か（部品と部品の間も含む）。
  let running: Bool
  /// `now` から見て次に予定で回る時刻。止めていれば nil。
  let next: Date?
  /// 最後の回が失敗した部品があるか。
  let failing: Bool

  /// 並びの群（この順に並ぶ）。走っているかは効かない——走り出すたびに行が跳ねないため。
  enum Group: Comparable {
    case failing
    case active
    case paused
  }

  var group: Group {
    if paused { return .paused }
    return failing ? .failing : .active
  }

  /// 名前の右の状態。走っているのを止めているより先に言う（止めていても流せる）。
  enum State: Equatable {
    case running
    case paused
  }

  var state: State? {
    if running { return .running }
    return paused ? .paused : nil
  }
}

extension BoardAutomationStanding {
  init(_ automation: Automation, runner: AutomationRunner, now: Date) {
    self.init(
      id: automation.id, name: automation.name, paused: automation.paused,
      running: runner.isRunning(automation.id) || runner.isFlowing(automation.id),
      next: runner.nextRunAt(automation, now: now), failing: automation.failing)
  }
}
