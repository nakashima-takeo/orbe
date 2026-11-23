import Foundation

/// 予約の時計。現在の時刻と、期限になったら、渡したキューの上で 1 回走らせる予約を持つ。裏の 1 回（`BackgroundProcess`）が、
/// 時刻の読みと、打ち切りの上限と猶予の予約を、ここに通す。本番は稼働時間（`uptime`）。
struct TimerClock: Sendable {
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
  /// 期限になったら、`queue` の上で `fire` を 1 回走らせる。返る閉包で取り消す。取り消しの閉包を捨てても、予約は残る。
  var schedule:
    @Sendable (_ deadline: Instant, _ queue: DispatchQueue, _ fire: @escaping () -> Void) ->
      @Sendable () -> Void
}

extension TimerClock {
  /// 稼働時間（`DispatchTime`。スリープの間は進まない）。予約は、`queue` の上の 1 回きりの `DispatchSourceTimer`。
  static let uptime: TimerClock = {
    let now: @Sendable () -> Instant = {
      Instant(seconds: TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000)
    }
    return TimerClock(
      now: now,
      schedule: { deadline, queue, fire in
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // タイマーは、発火するか取り消されるまで、自分のイベントハンドラから自分を保持する（取り消すと、ハンドラごと解放される）。
        timer.setEventHandler {
          timer.cancel()
          fire()
        }
        timer.schedule(deadline: .now() + max(0, deadline - now()))
        timer.resume()
        return { timer.cancel() }
      })
  }()
}
