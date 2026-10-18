import Foundation

/// 自動化 1 つの立ち位置——走っているか・止めているか・最後の回が失敗した部品があるか・最新の部品の回の区分——を 1 回だけ導いた
/// 値。並びの群・点の色・右端の種類はすべてここから読む（同じ判定が並び・点・文・色に散ると、優先順位が 1 か所だけずれる）。
/// 自動化そのものは持たない。
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
    return failing ? .failing : .active
  }

  /// 右端に出す 1 つ。走っている ＞ 失敗した部品 ＞ 止めている ＞ まだ回っていない ＞ 最新の回、の順に決まる。走っているのを
  /// 失敗より先に言うのは、直して流し直している最中に「で失敗」のままだと、↵ の断り「実行中のため…」と食い違うため。
  enum Mark: Equatable {
    case running
    case failed
    case paused
    case neverRan
    case ran(BoardRunTone)
  }

  var mark: Mark {
    if running { return .running }
    if failing && !paused { return .failed }
    if paused { return .paused }
    return last.map(Mark.ran) ?? .neverRan
  }
}

extension BoardAutomationStanding {
  init(_ automation: Automation, runner: AutomationRunner, now: Date) {
    self.init(
      id: automation.id, name: automation.name, paused: automation.paused,
      running: runner.isRunning(automation.id) || runner.isFlowing(automation.id),
      next: runner.nextRunAt(automation, now: now), failing: !automation.failedParts.isEmpty,
      last: automation.runs.first.map { BoardAutomationSummary.tone($0.run) })
  }
}
