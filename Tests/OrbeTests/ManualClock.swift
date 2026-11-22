import Foundation
import OrbeTestSupport

@testable import Orbe

/// 手で進める時計。時刻は `advance` を呼んだときだけ進む。本番の型へは `waits`（止める時計）を渡す。
///
/// テストは、偽スクリプトが止まったことと、待ち手が眠ったこと（`sleeping`）を待ってから時刻を進める。上限は時刻を進めたときにだけ
/// 来るので、結果がマシンの負荷に依らない。待ち手が眠る前に時刻が期限を過ぎていれば、待ち手は眠らずに期限切れを知る。
final class ManualClock: @unchecked Sendable {
  /// 眠っている待ち手。`id` は眠った順の番号で、起きて眠り直した待ち手は、別の番号になる。
  struct Sleeper: Equatable {
    let id: Int
    /// 期限。nil は期限なし。
    let deadline: WaitClock.Instant?
  }

  private struct Parked {
    let deadline: WaitClock.Instant?
    let unpark: @Sendable () -> Void
    var expired = false
  }

  private let lock = NSLock()
  private var current = WaitClock.wall.now()
  private var sleepers: [Int: Parked] = [:]
  private var nextID = 0
  private var reads = 0

  /// いまの時刻。読んでも `readings` は増えない。
  var now: WaitClock.Instant { lock.withLock { current } }

  /// 本番の型が時刻を読んだ回数。出力を受け取るたびに時刻を読む型では、出力が届いたことを、これが増えたことで待てる。
  var readings: Int { lock.withLock { reads } }

  /// いま眠っている待ち手。眠った順。
  var asleep: [Sleeper] {
    lock.withLock {
      sleepers.sorted { $0.key < $1.key }.filter { !$0.value.expired }
        .map { Sleeper(id: $0.key, deadline: $0.value.deadline) }
    }
  }

  /// いま眠っている待ち手の期限（期限なしは nil）。眠った順。
  var sleeping: [WaitClock.Instant?] { asleep.map(\.deadline) }

  /// `sleeper` が、まだ起きずに眠っているか。
  func isAsleep(_ sleeper: Sleeper) -> Bool {
    lock.withLock { sleepers[sleeper.id].map { !$0.expired } ?? false }
  }

  /// 本番の型へ渡す、止める時計。
  var waits: WaitClock {
    WaitClock(
      now: { [self] in
        lock.withLock {
          reads += 1
          return current
        }
      },
      sleep: { [self] deadline, park, unpark in
        let id = lock.withLock { () -> Int? in
          if let deadline, deadline <= current { return nil }
          nextID += 1
          sleepers[nextID] = Parked(deadline: deadline, unpark: unpark)
          return nextID
        }
        guard let id else { return false }
        _ = park(nil)
        return lock.withLock { sleepers.removeValue(forKey: id)?.expired == false }
      })
  }

  /// 時刻を `seconds` 進め、期限の来た待ち手を起こしてから返る。起こした数を返す。
  @discardableResult
  func advance(by seconds: TimeInterval) -> Int {
    advance(to: now + seconds)
  }

  /// 時刻を `instant` まで進め（過ぎていれば進めない）、期限の来た待ち手を起こしてから返る。起こした数を返す。
  @discardableResult
  func advance(to instant: WaitClock.Instant) -> Int {
    let woken = lock.withLock { () -> [@Sendable () -> Void] in
      current = max(current, instant)
      var woken: [@Sendable () -> Void] = []
      for (id, sleeper) in sleepers where !sleeper.expired {
        guard let deadline = sleeper.deadline, deadline <= current else { continue }
        sleepers[id]?.expired = true
        woken.append(sleeper.unpark)
      }
      return woken
    }
    for unpark in woken { unpark() }
    return woken.count
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
}
