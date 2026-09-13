import Foundation

/// 監視の変化を積み、注入された時刻から「次に出すべき時刻」を決める純状態機械。タイマーは持たない
/// （`RepoWatcher` が 1 本だけ張る）。後追い: 直近の変化から `debounce`。上限: 最初の保留から
/// `maximumDelay`——変わり続ける間（ビルド等）も 1 秒に 1 回は出る。
struct BatchDebounce {
  static let debounce: TimeInterval = 0.2
  static let maximumDelay: TimeInterval = 1.0

  /// 保留中の窓。最初の変化と直近の変化の時刻から期限が決まる。
  private struct Window {
    let first: Date
    var last: Date
    var due: Date {
      min(
        last.addingTimeInterval(BatchDebounce.debounce),
        first.addingTimeInterval(BatchDebounce.maximumDelay))
    }
  }

  private var pending = RepoWatcher.Batch()
  private var window: Window?

  /// 次に出すべき時刻。保留が無ければ nil。
  var dueDate: Date? { window?.due }

  /// 変化を積み、次に出すべき時刻を返す。
  mutating func note(_ batch: RepoWatcher.Batch, at now: Date) -> Date {
    pending.merge(batch)
    var window = self.window ?? Window(first: now, last: now)
    window.last = now
    self.window = window
    return window.due
  }

  /// 期限が来ていれば積んだ変化を取り出して空にする。まだなら nil（呼び手は `dueDate` で張り直す）。
  mutating func flush(at now: Date) -> RepoWatcher.Batch? {
    guard let window, now >= window.due else { return nil }
    defer {
      pending = RepoWatcher.Batch()
      self.window = nil
    }
    return pending
  }
}
