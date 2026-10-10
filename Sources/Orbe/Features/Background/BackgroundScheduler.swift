import AppKit
import Observation

/// 予定の番人。次の時刻を数え、時刻が来た予定の 1 回を始める。保存は持たない——使い手が自分の保存先から登録し、
/// 結果を受けて「最後に走った時刻」を自分で保存する。共有の資源（同時数・終了時の回収）は実行の係が持つので、
/// 使い手ごとに番人を持ってよい。main で使う。
///
/// 壁時計で待つ。待ちは最も早い出来事に合わせた予約 1 本で、その発火には頼らず、スリープ明け・時計の変更・タイムゾーンの
/// 変更で全予定を数え直す（毎日の時刻はタイムゾーンで意味が変わる）。
///
/// 登録は 2 つの形を持つ。仕事＋いつ（＋期限）の登録は、実行の係に仕事を渡して結果を返す。始め方の登録は、1 回を
/// 使い手の関数に任せ、終わりの知らせ（数え始め）を受けて数え直す——1 回が複数の段から成る使い手のため。
///
/// - 同じ予定は重ねて走らせない。走っている間に次の回が来ても積まず、終わった時点で数え直す。
/// - 再登録は「外す＋登録」。走っている回は止め、その結果は返さない（使い手の保存は完了時にしか進まないので、
///   止めた回は保存上「まだ走っていない」になり、番人の記憶と食い違わない）。
/// - 期限が来たら走っている回を止め（結果は返さない）、「期限が来た」を 1 度だけ返して予定を外す。
/// - いつを持たない予定は「今すぐ」でだけ走る。
///
/// 観測に乗るのは各予定が走っているか（`isRunning`。予定の出入りを含む）だけで、画面が「受信中…」を描くため。
/// 時計・予約・数え直しの印と、予定のいつ・数え始め・止める手は乗せない——乗せると、予約の張り直しや数え直しのたびに
/// 無関係な描き直しが走る。
@Observable final class BackgroundScheduler {
  enum Event: Equatable {
    case ran(BackgroundRunResult)
    case expired
  }

  typealias Run = (BackgroundJob, @escaping (BackgroundRunResult) -> Void) -> BackgroundRunHandle
  /// 1 回を始め、止める手を返す。終わったら `finish` に数え始め（その回の開始時刻）を渡す。
  typealias Start = (_ finish: @escaping (Date) -> Void) -> BackgroundRunHandle

  @ObservationIgnored var now: () -> Date = Date.init
  @ObservationIgnored var calendar: () -> Calendar = { Calendar.current }
  /// 壁時計の時刻に 1 度だけ発火する予約を張り、取り消す手を返す。
  @ObservationIgnored var arm: (Date, @escaping () -> Void) -> () -> Void =
    BackgroundScheduler.wallTimer

  private let run: Run
  private var entries: [String: Entry] = [:]
  @ObservationIgnored private var nextToken = 0
  @ObservationIgnored private var disarm: (() -> Void)?
  @ObservationIgnored private var recounting = false
  @ObservationIgnored private var recountAgain = false
  @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

  init(run: @escaping Run = { BackgroundRuns.shared.run($0, completion: $1) }) {
    self.run = run
    observeRecountTriggers()
  }

  deinit {
    disarm?()
    for (center, observer) in observers { center.removeObserver(observer) }
  }

  /// 仕事を登録する。`id` は使い手が名前空間を付ける（例「wait:12」）。`anchor` は数え始め。同じ `id` なら「外す＋登録」。
  func register(
    id: String, schedule: BackgroundSchedule, anchor: Date,
    onEvent: @escaping (Event) -> Void
  ) throws(BackgroundJobError) {
    try schedule.validate()
    let run = run
    add(
      id,
      Entry(timing: schedule.timing, deadline: schedule.deadline, anchor: anchor) { finish in
        run(schedule.job) { result in finish(result.startedAt) { onEvent(.ran(result)) } }
      } onExpire: {
        onEvent(.expired)
      })
  }

  /// 始め方を登録する。`timing` が nil なら「今すぐ」でだけ走る。同じ `id` なら「外す＋登録」。
  func register(id: String, timing: BackgroundTiming?, anchor: Date, start: @escaping Start)
    throws(BackgroundJobError)
  {
    try timing?.validate()
    add(
      id, Entry(timing: timing, deadline: nil, anchor: anchor) { finish in start { finish($0) {} } }
    )
  }

  /// いつだけを差し替えて数え直す（nil は「今すぐ」だけ）。走っている回は止めない。
  func retime(id: String, timing: BackgroundTiming?) throws(BackgroundJobError) {
    try timing?.validate()
    guard let entry = entries[id] else { return }
    entry.timing = timing
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

  func isRunning(id: String) -> Bool {
    entries[id]?.runToken != nil
  }

  private func add(_ id: String, _ entry: Entry) {
    drop(id)
    entries[id] = entry
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
      let deadline = entry.deadline
      if entry.runToken != nil {
        guard let deadline else { continue }
        if deadline <= now { expire(id, entry) } else { wake(at: deadline) }
        continue
      }
      guard let timing = entry.timing else { continue }
      // 時計が戻って未来になった数え始めは、今にそろえて覚える（次の時刻の関数も今から数えるが、覚えないと時計が戻っている間は次の回が今に連れて遠のき続ける）。
      if entry.anchor > now { entry.anchor = now }
      switch timing.next(after: entry.anchor, deadline: deadline, now: now, calendar: calendar) {
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
    let handle = entry.start { [weak self] anchor, deliver in
      self?.finished(id, token: token, anchor: anchor, deliver: deliver)
    }
    if entry.runToken == token { entry.handle = handle }
  }

  /// 外した回・期限で止めた回の終わりは捨てる。`deliver` は使い手への知らせで、数え直しより先に渡す。
  private func finished(_ id: String, token: Int, anchor: Date, deliver: () -> Void) {
    guard let entry = entries[id], entry.runToken == token else { return }
    entry.runToken = nil
    entry.handle = nil
    entry.anchor = anchor
    deliver()
    recount()
  }

  private func expire(_ id: String, _ entry: Entry) {
    drop(id)
    entry.onExpire()
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

  /// 番人の中での始め方。終わりの知らせは、数え直しより先に使い手へ渡す知らせを添える。
  fileprivate typealias EntryStart = (_ finish: @escaping (Date, () -> Void) -> Void) ->
    BackgroundRunHandle

  @Observable fileprivate final class Entry {
    @ObservationIgnored var timing: BackgroundTiming?
    let deadline: Date?
    @ObservationIgnored var anchor: Date
    let start: EntryStart
    let onExpire: () -> Void
    var runToken: Int?
    @ObservationIgnored var handle: BackgroundRunHandle?

    init(
      timing: BackgroundTiming?, deadline: Date?, anchor: Date, start: @escaping EntryStart,
      onExpire: @escaping () -> Void = {}
    ) {
      self.timing = timing
      self.deadline = deadline
      self.anchor = anchor
      self.start = start
      self.onExpire = onExpire
    }
  }
}
