import Foundation

/// 止める時計。現在の時刻と、合図か期限まで呼び出したスレッドを止める待ちを持つ。子プロセスの終わりを止まって待つ実行
/// （`GitRunner`・`GitHubCLI`・`ShellPATH`）が、時刻の読みと期限つきの待ちをここに通す。本番は壁時計（`wall`）。
struct WaitClock: Sendable {
  /// この時計の時刻。できるのは、秒を足す・比べる・差を秒で取ることだけ。
  struct Instant: Comparable, Sendable {
    fileprivate let seconds: TimeInterval

    static func + (instant: Instant, interval: TimeInterval) -> Instant {
      Instant(seconds: instant.seconds + interval)
    }

    static func - (later: Instant, earlier: Instant) -> TimeInterval {
      later.seconds - earlier.seconds
    }

    static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.seconds < rhs.seconds }
  }

  /// 現在の時刻。
  var now: @Sendable () -> Instant
  /// 合図か期限（nil は期限なし）まで、呼び出したスレッドを止める。期限で起きたら false。期限を過ぎて呼ばれたら、止まらずに、
  /// 届いている合図を優先して返す（合図が届いていれば true）。
  /// `park` は、渡した秒数まで（nil は合図まで）止まり、合図で起きたら true を返す処理。`unpark` はそれを解く合図。
  var sleep:
    @Sendable (
      _ deadline: Instant?, _ park: (TimeInterval?) -> Bool,
      _ unpark: @escaping @Sendable () -> Void
    ) -> Bool
}

extension WaitClock {
  /// `semaphore` の合図か期限まで止まる。期限で起きたら false。
  @discardableResult
  func sleep(on semaphore: DispatchSemaphore, until deadline: Instant?) -> Bool {
    sleep(
      deadline,
      { seconds in
        guard let seconds else {
          semaphore.wait()
          return true
        }
        return semaphore.wait(timeout: .now() + seconds) == .success
      },
      { semaphore.signal() })
  }

  /// `condition` の合図（`broadcast`）か期限まで止まる。期限で起きたら false。`condition` の鍵を持ったまま呼ぶ。
  @discardableResult
  func sleep(on condition: NSCondition, until deadline: Instant?) -> Bool {
    sleep(
      deadline,
      { seconds in
        guard let seconds else {
          condition.wait()
          return true
        }
        return condition.wait(until: Date().addingTimeInterval(seconds))
      },
      {
        condition.lock()
        condition.broadcast()
        condition.unlock()
      })
  }

  /// 壁時計（`Date`）。待ちは、期限までの残りの秒数を渡した `park` そのもの（タイマーを作らない）。
  static let wall: WaitClock = {
    let now: @Sendable () -> Instant = { Instant(seconds: Date().timeIntervalSinceReferenceDate) }
    return WaitClock(
      now: now, sleep: { deadline, park, _ in park(deadline.map { max(0, $0 - now()) }) })
  }()
}
