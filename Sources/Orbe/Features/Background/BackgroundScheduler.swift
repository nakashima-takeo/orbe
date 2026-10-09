import AppKit

/// 予定の番人。次の時刻を数え、時刻が来た予定を実行の係へ渡す。保存は持たない——使い手が自分の保存先から登録し、
/// 結果を受けて「最後に走った時刻」を自分で保存する。共有の資源（同時数・終了時の回収）は実行の係が持つので、
/// 使い手ごとに番人を持ってよい。main で使う。
///
/// 壁時計で待つ。待ちは最も早い出来事に合わせた予約 1 本で、その発火には頼らず、スリープ明け・時計の変更・タイムゾーンの
/// 変更で全予定を数え直す（毎日の時刻はタイムゾーンで意味が変わる）。
///
/// - 同じ予定は重ねて走らせない。走っている間に次の回が来ても積まず、終わった時点で数え直す。
/// - 再登録は「外す＋登録」。走っている回は止め、その結果は返さない（使い手の保存は完了時にしか進まないので、
///   止めた回は保存上「まだ走っていない」になり、番人の記憶と食い違わない）。
/// - 期限が来たら走っている回を止め（結果は返さない）、「期限が来た」を 1 度だけ返して予定を外す。
final class BackgroundScheduler {
  enum Event: Equatable {
    case ran(BackgroundRunResult)
    case expired
  }

  typealias Run = (BackgroundJob, @escaping (BackgroundRunResult) -> Void) -> BackgroundRunHandle

  var now: () -> Date = Date.init
  var calendar: () -> Calendar = { Calendar.current }
  /// 壁時計の時刻に 1 度だけ発火する予約を張り、取り消す手を返す。
  var arm: (Date, @escaping () -> Void) -> () -> Void = BackgroundScheduler.wallTimer

  private let run: Run
  private var entries: [String: Entry] = [:]
  private var nextToken = 0
  private var disarm: (() -> Void)?
  private var recounting = false
  private var recountAgain = false
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []

  init(run: @escaping Run = { BackgroundRuns.shared.run($0, completion: $1) }) {
    self.run = run
    observeRecountTriggers()
  }

  deinit {
    disarm?()
    for (center, observer) in observers { center.removeObserver(observer) }
  }

  /// 登録する。`id` は使い手が名前空間を付ける（例「wait:12」）。`anchor` は数え始め。同じ `id` なら「外す＋登録」。
  func register(
    id: String, schedule: BackgroundSchedule, anchor: Date,
    onEvent: @escaping (Event) -> Void
  ) throws(BackgroundJobError) {
    try schedule.validate()
    drop(id)
    entries[id] = Entry(schedule: schedule, anchor: anchor, onEvent: onEvent)
    recount()
  }

  /// 外す。走っている回は止め、その結果は返さない。
  func remove(id: String) {
    drop(id)
    recount()
  }

  /// 今すぐ走らせる。走っている間は何もしない。
  func runNow(id: String) {
    guard let entry = entries[id], entry.runToken == nil else { return }
    start(id, entry)
    recount()
  }

  /// 全予定を数え直し、次の予約を張り直す。
  func recount() {
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
    let now = now()
    let calendar = calendar()
    var earliest: Date?
    func wake(at date: Date) { earliest = min(earliest ?? date, date) }

    for id in entries.keys.sorted() {
      guard let entry = entries[id] else { continue }
      let deadline = entry.schedule.deadline
      if entry.runToken != nil {
        guard let deadline else { continue }
        if deadline <= now { expire(id, entry) } else { wake(at: deadline) }
        continue
      }
      // 時計が戻って数え始めが未来になったら、今にそろえる（そのままでは次の回が戻った分だけ遠のき、予定が止まる）。
      if entry.anchor > now { entry.anchor = now }
      switch entry.schedule.timing.next(
        after: entry.anchor, deadline: deadline, now: now, calendar: calendar)
      {
      case .expire(let date):
        if date <= now { expire(id, entry) } else { wake(at: date) }
      case .run(let date):
        guard date <= now else {
          wake(at: date)
          continue
        }
        start(id, entry)
        if let deadline { wake(at: deadline) }
      }
    }
    disarm?()
    disarm = earliest.map { arm($0) { [weak self] in self?.recount() } }
  }

  private func start(_ id: String, _ entry: Entry) {
    nextToken += 1
    let token = nextToken
    entry.runToken = token
    let handle = run(entry.schedule.job) { [weak self] result in
      self?.finished(id, token: token, result: result)
    }
    if entry.runToken == token { entry.handle = handle }
  }

  private func finished(_ id: String, token: Int, result: BackgroundRunResult) {
    guard let entry = entries[id], entry.runToken == token else { return }
    entry.runToken = nil
    entry.handle = nil
    entry.anchor = result.startedAt
    entry.onEvent(.ran(result))
    recount()
  }

  private func expire(_ id: String, _ entry: Entry) {
    drop(id)
    entry.onEvent(.expired)
  }

  private func drop(_ id: String) {
    entries.removeValue(forKey: id)?.handle?.stop()
  }

  private func observeRecountTriggers() {
    let workspace = NSWorkspace.shared.notificationCenter
    let local = NotificationCenter.default
    let triggers: [(NotificationCenter, Notification.Name)] = [
      (workspace, NSWorkspace.didWakeNotification),
      (local, .NSSystemClockDidChange),
      (local, .NSSystemTimeZoneDidChange),
    ]
    for (center, name) in triggers {
      let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] in
        if $0.name == .NSSystemTimeZoneDidChange { NSTimeZone.resetSystemTimeZone() }
        self?.recount()
      }
      observers.append((center, observer))
    }
  }

  static func wallTimer(at date: Date, fire: @escaping () -> Void) -> () -> Void {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    let seconds = date.timeIntervalSince1970.rounded(.down)
    let nanoseconds = (date.timeIntervalSince1970 - seconds) * 1_000_000_000
    timer.schedule(
      wallDeadline: DispatchWallTime(
        timespec: timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))))
    timer.setEventHandler(handler: fire)
    timer.resume()
    return { timer.cancel() }
  }

  private final class Entry {
    let schedule: BackgroundSchedule
    var anchor: Date
    let onEvent: (Event) -> Void
    var runToken: Int?
    var handle: BackgroundRunHandle?

    init(schedule: BackgroundSchedule, anchor: Date, onEvent: @escaping (Event) -> Void) {
      self.schedule = schedule
      self.anchor = anchor
      self.onEvent = onEvent
    }
  }
}
