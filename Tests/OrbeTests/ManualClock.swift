import Foundation
import OrbeTestSupport

@testable import Orbe

/// 手で進める時計。時刻は `advance` を呼んだときだけ進む。本番の型へは `waits`（止める時計）か `makeTimers()` の `clock`（予約の時計）を渡す。
/// 2 つの時計の時刻は、同じだけ進む。
///
/// テストは、偽スクリプトが止まったことと、待ち手が眠ったこと（`sleepingDeadlines`）や予約が張られたこと（`scheduled`）を待ってから
/// 時刻を進める。期限は時刻を進めたときにだけ来るので、結果がマシンの負荷に依らない。待ち手が眠る前に時刻が期限を過ぎていれば、
/// 待ち手は眠らずに、届いている合図を受け取るか、期限切れを知る。期限の来た予約は、時刻を進めた呼び出しの中で、その予約のキューの上で走り終える。
final class ManualClock: @unchecked Sendable {
  /// 眠っている待ち手。`id` は眠った順の番号で、起きて眠り直した待ち手は、別の番号になる。
  struct Sleeper: Equatable {
    let id: Int
    /// 期限。nil は期限なし。
    let deadline: WaitClock.Instant?
  }

  /// 張られている予約。`id` は張った順の番号で、張り直した予約は、別の番号になる。
  struct Reservation: Equatable {
    let id: Int
    let deadline: TimerClock.Instant
    /// 張った渡し先（`Timers.id`）。
    let owner: Int
  }

  /// 予約の時計の、1 つの渡し先。この渡し先が時刻を読んだ回数と張った予約を、同じ時刻を使うほかの渡し先のものと見分ける。
  struct Timers {
    let id: Int
    /// 本番の型へ渡す、予約の時計。
    let clock: TimerClock
  }

  private struct Parked {
    let deadline: WaitClock.Instant?
    let unpark: @Sendable () -> Void
    var expired = false
  }

  private struct Armed {
    let deadline: TimerClock.Instant
    let owner: Int
    let queue: DispatchQueue
    let fire: () -> Void
  }

  /// 2 つの時計の時刻。どちらも同じだけ進む。どちらかの時計を期限まで進めたとき、その時計の時刻は期限と等しくなる。
  private struct Time {
    var wait: WaitClock.Instant
    var timer: TimerClock.Instant
  }

  private let lock = NSLock()
  private var current = Time(wait: WaitClock.wall.now(), timer: TimerClock.uptime.now())
  private var sleepers: [Int: Parked] = [:]
  private var reservations: [Int: Armed] = [:]
  private var nextID = 0
  private var reads = 0
  private var readsByOwner: [Int: Int] = [:]

  /// いまの時刻（止める時計の時刻）。読んでも `readings` は増えない。
  var now: WaitClock.Instant { lock.withLock { current.wait } }

  /// いまの時刻（予約の時計の時刻）。読んでも `readings` は増えない。
  var timerNow: TimerClock.Instant { lock.withLock { current.timer } }

  /// 本番の型が時刻を読んだ回数（2 つの時計の合計）。出力を受け取るたびに時刻を読む型では、出力が届いたことを、
  /// `readings` が増えたことで待てる。
  var readings: Int { lock.withLock { reads } }

  /// `timers` を渡した本番の型が、予約の時計の時刻を読んだ回数。
  func readings(of timers: Timers) -> Int { lock.withLock { readsByOwner[timers.id, default: 0] } }

  /// いま眠っている待ち手。眠った順。
  var asleep: [Sleeper] {
    lock.withLock {
      sleepers.sorted { $0.key < $1.key }.filter { !$0.value.expired }
        .map { Sleeper(id: $0.key, deadline: $0.value.deadline) }
    }
  }

  /// いま眠っている待ち手の期限（期限なしは nil）。眠った順。
  var sleepingDeadlines: [WaitClock.Instant?] { asleep.map(\.deadline) }

  /// `sleeper` が、まだ起きずに眠っているか。
  func isAsleep(_ sleeper: Sleeper) -> Bool {
    lock.withLock { sleepers[sleeper.id].map { !$0.expired } ?? false }
  }

  /// いま張られている予約（走っておらず、取り消されていないもの）。張った順。
  var scheduled: [Reservation] {
    lock.withLock {
      reservations.sorted { $0.key < $1.key }.map {
        Reservation(id: $0.key, deadline: $0.value.deadline, owner: $0.value.owner)
      }
    }
  }

  /// `reservation` が、まだ走らず、取り消されずに張られているか。
  func isScheduled(_ reservation: Reservation) -> Bool {
    lock.withLock { reservations[reservation.id] != nil }
  }

  /// 本番の型へ渡す、止める時計。
  var waits: WaitClock {
    WaitClock(
      now: { [self] in
        lock.withLock {
          reads += 1
          return current.wait
        }
      },
      sleep: { [self] deadline, park, unpark in
        let id = lock.withLock { () -> Int? in
          if let deadline, deadline <= current.wait { return nil }
          nextID += 1
          sleepers[nextID] = Parked(deadline: deadline, unpark: unpark)
          return nextID
        }
        // 期限が過ぎていれば止まらず、本番の時計と同じく、届いている合図を優先して返す。
        guard let id else { return park(0) }
        _ = park(nil)
        return lock.withLock { sleepers.removeValue(forKey: id)?.expired == false }
      })
  }

  /// 予約の時計の、新しい渡し先を作る。張った時点で期限が過ぎている予約は、次に時刻を進めたときに走る。
  func makeTimers() -> Timers {
    let owner = lock.withLock { () -> Int in
      nextID += 1
      return nextID
    }
    let clock = TimerClock(
      now: { [self] in
        lock.withLock {
          reads += 1
          readsByOwner[owner, default: 0] += 1
          return current.timer
        }
      },
      schedule: { [self] deadline, queue, fire in
        let id = lock.withLock { () -> Int in
          nextID += 1
          reservations[nextID] = Armed(deadline: deadline, owner: owner, queue: queue, fire: fire)
          return nextID
        }
        return { [self] in _ = lock.withLock { reservations.removeValue(forKey: id) } }
      })
    return Timers(id: owner, clock: clock)
  }

  /// 時刻を `seconds` 進める。起こした待ち手の数と走らせた予約の数の和を返す（`advance(to:)` と同じ）。
  @discardableResult
  func advance(by seconds: TimeInterval) -> Int {
    advance { Time(wait: $0.wait + seconds, timer: $0.timer + seconds) }
  }

  /// 時刻を、止める時計の `instant` まで進める（過ぎていれば進めない）。期限の来た予約を走らせ、期限の来た待ち手を起こしてから
  /// 返る。起こした数と走らせた数の和を返す。
  @discardableResult
  func advance(to instant: WaitClock.Instant) -> Int {
    advance { Time(wait: instant, timer: $0.timer + (instant - $0.wait)) }
  }

  /// 時刻を、予約の時計の `instant` まで進める（過ぎていれば進めない）。ほかは、止める時計の時刻を取る `advance(to:)` と同じ。
  @discardableResult
  func advance(to instant: TimerClock.Instant) -> Int {
    advance { Time(wait: $0.wait + (instant - $0.timer), timer: instant) }
  }

  /// 時刻を進める、唯一の場所。期限の来た予約を、期限の順に、時刻をその期限まで進めてから、その予約のキューの上で走らせる
  /// （走った処理が張った予約も、期限が来ていれば走らせる）。最後に `target` まで進めて、期限の来た待ち手を起こす。
  /// 予約を走らせるのも、待ち手を起こすのも、鍵の外で行う。
  private func advance(_ target: (Time) -> Time) -> Int {
    let goal = lock.withLock { target(current) }
    var fired = 0
    while let (id, queue) = lock.withLock({ () -> (Int, DispatchQueue)? in
      guard
        let (id, due) = reservations.filter({ $0.value.deadline <= goal.timer })
          .min(by: { ($0.value.deadline, $0.key) < ($1.value.deadline, $1.key) })
      else { return nil }
      if current.timer < due.deadline {
        current = Time(wait: current.wait + (due.deadline - current.timer), timer: due.deadline)
      }
      return (id, due.queue)
    }) {
      // 取り消しは本番のキューの上で起きるので、走らせる直前に、同じキューの上で、まだ張られているかを見る。
      queue.sync {
        guard let fire = lock.withLock({ reservations.removeValue(forKey: id)?.fire }) else {
          return
        }
        fire()
        fired += 1
      }
    }
    let woken = lock.withLock { () -> [@Sendable () -> Void] in
      current = Time(wait: max(current.wait, goal.wait), timer: max(current.timer, goal.timer))
      var woken: [@Sendable () -> Void] = []
      for (id, sleeper) in sleepers where !sleeper.expired {
        guard let deadline = sleeper.deadline, deadline <= current.wait else { continue }
        sleepers[id]?.expired = true
        woken.append(sleeper.unpark)
      }
      return woken
    }
    for unpark in woken { unpark() }
    return woken.count + fired
  }

  /// 期限が `deadline`（nil は期限なし）の待ち手が眠るまで、ランループを回して待ち、その待ち手を返す。眠らなければ nil。
  @discardableResult
  func awaitSleeper(until deadline: WaitClock.Instant?, timeout: TimeInterval = 10) -> Sleeper? {
    awaitSleeper(timeout: timeout) { $0.deadline == deadline }
  }

  /// `match` に合う待ち手が眠るまで、ランループを回して待ち、その待ち手を返す。眠らなければ nil。
  func awaitSleeper(timeout: TimeInterval = 10, where match: (Sleeper) -> Bool) -> Sleeper? {
    var found: Sleeper?
    waitUntil(timeout) {
      found = asleep.first(where: match)
      return found != nil
    }
    return found
  }

  /// `match` に合う予約が張られるまで、ランループを回して待ち、その予約を返す。張られなければ nil。
  func awaitReservation(
    timeout: TimeInterval = 10, where match: (Reservation) -> Bool = { _ in true }
  ) -> Reservation? {
    var found: Reservation?
    waitUntil(timeout) {
      found = scheduled.first(where: match)
      return found != nil
    }
    return found
  }
}
