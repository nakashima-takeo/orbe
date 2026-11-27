import AppKit

/// 12 時間超過の `TODAY` タブ自動整理を壁時計で駆動するスケジューラ。
/// スリープ復帰（`NSWorkspace.didWakeNotification`）とシステム時計変更（`.NSSystemClockDidChange`）で再計算する。
@MainActor
final class BrowserTabCleaner {
  typealias Arm = (Date, @escaping () -> Void) -> () -> Void

  var now: () -> Date
  var arm: Arm
  var nextFireDate: () -> Date?
  var onSweep: (Date) -> Void

  private(set) var isStarted = false
  private var disarm: (() -> Void)?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private var recounting = false
  private var recountAgain = false

  init(
    now: @escaping () -> Date = Date.init,
    arm: @escaping Arm = BackgroundScheduler.wallTimer,
    nextFireDate: @escaping () -> Date? = { nil },
    onSweep: @escaping (Date) -> Void = { _ in }
  ) {
    self.now = now
    self.arm = arm
    self.nextFireDate = nextFireDate
    self.onSweep = onSweep
  }

  deinit {
    disarm?()
    for (center, observer) in observers {
      center.removeObserver(observer)
    }
  }

  func start() {
    guard !isStarted else {
      recount()
      return
    }
    isStarted = true
    observeTriggers()
    recount()
  }

  func stop() {
    isStarted = false
    disarm?()
    disarm = nil
    for (center, observer) in observers {
      center.removeObserver(observer)
    }
    observers.removeAll()
  }

  func recount() {
    guard isStarted else { return }
    guard !recounting else {
      recountAgain = true
      return
    }
    recounting = true
    defer { recounting = false }
    repeat {
      recountAgain = false
      pass()
    } while recountAgain
  }

  private func pass() {
    disarm?()
    disarm = nil
    let current = now()
    if let due = nextFireDate(), due <= current {
      onSweep(current)
    }
    guard isStarted, let next = nextFireDate() else { return }
    // DB 書込失敗などで期限超過行が残った場合に即時ループへ陥らないよう、未来時刻のみ予約する。
    guard next > current else { return }
    disarm = arm(next) { [weak self] in
      self?.recount()
    }
  }

  private func observeTriggers() {
    let triggers: [(NotificationCenter, Notification.Name)] = [
      (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
      (NotificationCenter.default, .NSSystemClockDidChange),
    ]
    for (center, name) in triggers {
      let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.recount() }
      }
      observers.append((center, observer))
    }
  }
}
