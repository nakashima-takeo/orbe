import Foundation

/// 読めば取る行の数を、古さの上限を過ぎた行を除いた数に保つ。数えた行のどれかが上限を過ぎる最も早い時刻の、次の分の境で
/// 数え直す——画面は分の境で描き直すので、それより細かく数え直しても見えず、上限を過ぎる行が多くても数え直しは 1 分に高々
/// 1 回で済む。起こす決まりは上流の番号で言うので、この数を読まない。
extension AutomationRunner {
  /// 次の数え直しの時刻を合わせ直す（ストアの変異が通るたび）。過ぎた期限（数え直しに失敗した後も残る）は今から数える——
  /// 遅延 0 で張り直し続けて main を空回りさせないため。
  func scheduleRecount() {
    let now = now()
    let next = store.nextPendingExpiry.map { Self.minute(after: max($0, now)) }
    guard next != recountAt else { return }
    recountTimer?.invalidate()
    recountTimer = nil
    recountAt = next
    guard let next else { return }
    let delay = max(0, next.timeIntervalSince(now))
    let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.recountExpired() }
    }
    RunLoop.main.add(timer, forMode: .common)
    recountTimer = timer
  }

  /// 古さの上限を過ぎた受け手を数え直す。
  func recountExpired() {
    recountTimer = nil
    recountAt = nil
    do throws(AutomationError) {
      try store.recountExpired(now: now())
    } catch {
      NSLog("[automation] cannot recount the rows to read: \(error)")
    }
    scheduleRecount()
  }

  /// `date` より後の最初の分の境。
  static func minute(after date: Date) -> Date {
    Date(
      timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        + 60)
  }
}
