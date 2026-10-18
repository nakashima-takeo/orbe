import Foundation

/// 自動化の部品を 1 つずつ番人に載せ、部品の契機ごとに「溜まりから取る → 部品の 1 回 → 確定」を回す。main で使う。
///
/// 番人の鍵は `automation:<id>/<部品の鍵>`。間隔・cron の部品は止めていなければ「いつ」付きで、それ以外（手動・届いたら・
/// 止めた自動化の部品）は「いつ」なしで載せる。同じ部品の契機は重ならない（重ねない保証・「今すぐ」・走っているかは番人が
/// 持つ）。1 つの契機の中では、契機の始まりの時点で溜まっていた行を取り切るまで続けて回し、回が失敗するか書けなければ
/// その契機を終える。
///
/// 「届いたら」の部品を起こす決まりは 1 つ: 前の契機の始まりの時点の最も新しい通し番号より新しい行が溜まりにあり、走って
/// いなければ起こす。この決まりは、その部品の溜まりが増えたとき（上流の確定）・登録したとき（起動・書き換え・再開。止めた
/// 自動化は除く）・その部品の契機が終わったときに見る。失敗した契機の行は前の契機の番号以下なので、この決まりでは起こさない
/// （同じ行で失敗をすぐ繰り返さない）。代わりに、「届いたら」でない部品の契機が終わるたびに、下流の「届いたら」の部品を
/// 溜まりがあればすべて起こす（祖先の予定の間隔でやり直す）。
///
/// 流す（`flow`）は、部品を指してそこに至る道の上の部品を 1 回ずつ回す（`AutomationFlow`）。一巡は自動化ごとに高々 1 つで、
/// メモリだけに持つ。走らせ役は契機の始まりと終わりを一巡へ知らせ、返った部品を「今すぐ」で起こす。道の上の部品を番人から
/// 外すと一巡を打ち切る——待っている回の終わりが来なくなるので。
///
/// 部品の回を記録するたびに `recorded` で自動化と部品の鍵を知らせる（知らせるかどうか・何を出すかは受けた側がストアの今の値
/// から決める）。定義を書いたら `defined`、消したら `deleted` で知らせる。
final class AutomationRunner {
  let store: AutomationStore
  var now: () -> Date = Date.init
  var calendar: () -> Calendar = { Calendar.current }

  private let scheduler: BackgroundScheduler
  private let run: BackgroundScheduler.Run
  let workspaces: () -> AutomationWorkspaces
  private let recorded: (Int, String) -> Void
  private let defined: (Int) -> Void
  private let deleted: (Int) -> Void
  /// 番人に載せている鍵。
  private var registered = Set<String>()
  /// 部品ごとの、前の契機の始まりの時点の最も新しい通し番号（メモリだけ。無ければ溜まりの行はすべて新しい）。
  private var marks: [String: Int] = [:]
  /// 部品ごとの、番人に最後に返した数え始め。記録の無い契機（取る行が 0 件）でも進むので、次の時刻はこれから数える。
  private var anchors: [String: Date] = [:]
  /// 自動化ごとの、流している途中の一巡。
  private var flows: [Int: AutomationFlow] = [:]

  /// `workspaces` はタスク候補の付け先にできる今の workspace。判定の部品にだけ渡す。
  init(
    store: AutomationStore, scheduler: BackgroundScheduler = BackgroundScheduler(),
    run: @escaping BackgroundScheduler.Run = { BackgroundRuns.shared.run($0, completion: $1) },
    workspaces: @escaping () -> AutomationWorkspaces,
    recorded: @escaping (Int, String) -> Void, defined: @escaping (Int) -> Void,
    deleted: @escaping (Int) -> Void
  ) {
    self.store = store
    self.scheduler = scheduler
    self.run = run
    self.workspaces = workspaces
    self.recorded = recorded
    self.defined = defined
    self.deleted = deleted
    store.onUnavailable = { [weak self] in self?.unregisterAll() }
  }

  /// 起動時に一度、全部品を番人へ載せ、止めていない自動化の「届いたら」の部品に起こす決まりを見る（過ぎていた間隔の回は
  /// ここで 1 回だけ走る）。
  func start() {
    for automation in store.automations { register(automation) }
  }

  /// どれかの部品が走っているか。
  func isRunning(_ id: Int) -> Bool {
    store.automation(id)?.graph.nodes.contains { isRunning(id, $0.key) } ?? false
  }

  func isRunning(_ id: Int, _ key: String) -> Bool {
    scheduler.isRunning(id: Self.key(id, key))
  }

  /// `now`（渡さなければ走らせ役の今）から見て、どれかの部品が次に予定で回る時刻（止めていれば nil）。
  func nextRunAt(_ automation: Automation, now: Date? = nil) -> Date? {
    automation.graph.nodes.compactMap { nextRunAt(automation, part: $0.key, now: now) }.min()
  }

  /// 部品が次に予定で回る時刻。止めている・予定の無い部品は nil。過ぎていれば `now` 以前の時刻を返す。
  func nextRunAt(_ automation: Automation, part key: String, now: Date? = nil) -> Date? {
    guard !automation.paused, let node = automation.graph.node(key),
      case .scheduled(let timing) = node.part.trigger
    else { return nil }
    let anchor = anchors[Self.key(automation.id, key)] ?? automation.state(key).anchor
    switch timing.next(after: anchor, deadline: nil, now: now ?? self.now(), calendar: calendar()) {
    case .run(let date): return date
    case .expire: return nil
    }
  }

  // MARK: - 定義の変異

  /// `id` が nil なら作り、あれば丸ごと置き換える。何をするかが変わった部品は走っている回を止めて載せ直し（結果は捨てる）、
  /// 消えた部品は外し、足した部品は足した時刻から数える。名前・予定・取得の性質・溜まりの上限・通知だけなら予定だけを
  /// 差し替える（走っている回は最後まで走る）。
  func set(_ id: Int?, _ definition: AutomationDefinition) throws(AutomationError) -> Automation {
    try checkAvailable()
    guard let id else {
      let automation = try store.create(definition, now: now())
      register(automation)
      defined(automation.id)
      return automation
    }
    let replaced = try store.replace(id, with: definition, now: now())
    let automation = replaced.automation
    for key in replaced.removed { unregister(id, key) }
    for key in replaced.reworked { unregister(id, key) }
    register(automation)
    defined(id)
    return automation
  }

  /// 止めるのは時刻による予定と起動時の起こしだけ。走っている回は止めない。再開したら起こす決まりを見る。
  func pause(_ id: Int, _ paused: Bool) throws(AutomationError) -> Automation {
    try checkAvailable()
    let automation = try store.setPaused(id, paused)
    register(automation)
    return automation
  }

  /// 消す。走っている回は止め、その結果は捨てる。
  func delete(_ id: Int) throws(AutomationError) {
    try checkAvailable()
    let keys = store.automation(id)?.graph.nodes.map(\.key) ?? []
    try store.delete(id)
    for key in keys { unregister(id, key) }
    deleted(id)
  }

  /// 指した部品まで流す（止めた自動化も受ける）。流している途中なら断る。
  func flow(_ id: Int, to target: AutomationFlow.Target) throws(AutomationError) {
    try checkAvailable()
    guard let automation = store.automation(id) else { throw .automationNotFound(id) }
    let targets: [String]
    switch target {
    case .part(let key):
      guard automation.graph.node(key) != nil else { throw .partNotFound(id, key) }
      targets = [key]
    case .ends:
      targets = automation.graph.ends.map(\.key)
    }
    guard flows[id] == nil else { throw .flowing(id) }
    let (flow, wake) = AutomationFlow.start(to: targets, in: automation.graph) {
      isRunning(id, $0)
    }
    // 「今すぐ」の中で契機が同期に始まり終わりうるので、起こす前に一巡を置く。
    flows[id] = flow
    for part in wake { scheduler.runNow(id: Self.key(id, part)) }
  }

  private func checkAvailable() throws(AutomationError) {
    guard store.available else { throw AutomationStore.unavailableError }
  }

  // MARK: - 番人への登録

  static func key(_ id: Int, _ key: String) -> String { "automation:\(id)/\(key)" }

  /// 全部品を番人に合わせる。載っていない部品は載せ（数え始めは部品の最後に回った時刻、無ければ足した時刻）、載っている部品は
  /// 予定だけを差し替える。止めていなければ「届いたら」の部品に起こす決まりを見る。
  private func register(_ automation: Automation) {
    let id = automation.id
    for node in automation.graph.nodes {
      let key = Self.key(id, node.key)
      var timing: BackgroundTiming?
      if !automation.paused, case .scheduled(let scheduled) = node.part.trigger {
        timing = scheduled
      }
      if registered.contains(key) {
        try? scheduler.retime(id: key, timing: timing)
        continue
      }
      let part = node.key
      let start: BackgroundScheduler.Start = { [weak self] trigger, finish in
        self?.begin(id, part, trigger, finish) ?? BackgroundRunHandle {}
      }
      try? scheduler.register(
        id: key, timing: timing, anchor: automation.state(part).anchor, start: start)
      registered.insert(key)
    }
    guard !automation.paused else { return }
    for node in automation.graph.nodes { wake(id, node.key) }
  }

  /// 外す。走っている回は止め、その結果は捨てる。起こす決まりの番号と数え始めも忘れ、この部品を道に含む一巡を打ち切る。
  private func unregister(_ id: Int, _ part: String) {
    let key = Self.key(id, part)
    if flows[id]?.path.contains(part) == true { flows[id] = nil }
    scheduler.remove(id: key)
    registered.remove(key)
    marks[key] = nil
    anchors[key] = nil
  }

  private func unregisterAll() {
    flows = [:]
    for key in registered { scheduler.remove(id: key) }
    registered = []
    marks = [:]
    anchors = [:]
  }

  /// 起こす決まり。「届いたら」の部品に、前の契機の始まりの時点より新しい行が溜まりにあり、走っていなければ起こす。
  private func wake(_ id: Int, _ part: String) {
    guard let automation = store.automation(id), let node = automation.graph.node(part),
      node.part.trigger == .arrival
    else { return }
    let key = Self.key(id, part)
    guard automation.state(part).newestSeq > marks[key] ?? 0, !scheduler.isRunning(id: key) else {
      return
    }
    scheduler.runNow(id: key)
  }

  /// 失敗のやり直し。「届いたら」でない部品の契機が終わったら、下流の「届いたら」の部品を溜まりがあればすべて起こす。
  private func retry(below part: String, in id: Int) {
    guard let automation = store.automation(id) else { return }
    for node in automation.graph.descendants(of: part)
    where node.part.trigger == .arrival && automation.state(node.key).inbox > 0 {
      scheduler.runNow(id: Self.key(id, node.key))
    }
  }
}

/// 部品の契機。
extension AutomationRunner {
  /// 走っている契機。止められたら、以後の結果は捨てる。
  private final class Trigger {
    let automationId: Int
    let part: String
    let kind: AutomationPartRun.Trigger
    let startedAt: Date
    let finish: (Date) -> Void
    /// 契機の始まりの時点の、溜まりの最も新しい通し番号。これ以下の行を取り切るまで続ける。
    var mark = 0
    /// 最後の回の始まり。
    var lastStart: Date?
    var current: BackgroundRunHandle?
    var cancelled = false
    /// 一巡の分として受け取った契機か。
    var flowed = false

    init(
      automationId: Int, part: String, kind: AutomationPartRun.Trigger, startedAt: Date,
      finish: @escaping (Date) -> Void
    ) {
      self.automationId = automationId
      self.part = part
      self.kind = kind
      self.startedAt = startedAt
      self.finish = finish
    }
  }

  private func begin(
    _ id: Int, _ part: String, _ kind: BackgroundScheduler.Trigger,
    _ finish: @escaping (Date) -> Void
  ) -> BackgroundRunHandle {
    // 番人の上に「走っている」を残さないよう、部品が無ければ契機はすぐ終わったものとして知らせる。
    guard let node = store.automation(id)?.graph.node(part) else {
      finish(now())
      return BackgroundRunHandle {}
    }
    let trigger = Trigger(
      automationId: id, part: part,
      kind: node.part.trigger == .arrival ? .arrival : kind == .now ? .now : .schedule,
      startedAt: now(), finish: finish)
    trigger.flowed = flows[id]?.started(part) ?? false
    if node.part.inputs.isEmpty {
      pass(trigger, take: nil)
    } else {
      trigger.mark = store.automation(id)?.state(part).newestSeq ?? 0
      marks[Self.key(id, part)] = trigger.mark
      takeNext(trigger)
    }
    return BackgroundRunHandle {
      trigger.cancelled = true
      trigger.current?.stop()
    }
  }

  /// 契機の始まりの時点の行から、`AutomationInbox.take` で取る行を選ぶ。取る行が 0 件なら手段を起こさず、捨てる行だけを
  /// 捨てて終える。
  private func takeNext(_ trigger: Trigger) {
    guard !trigger.cancelled else { return }
    guard let automation = store.automation(trigger.automationId),
      let node = automation.graph.node(trigger.part),
      let rows = try? store.inbox(of: trigger.part, in: trigger.automationId)
    else { return end(trigger) }
    let proposed = Set(store.proposals.map(\.item.link))
    let context = AutomationInbox.Context(
      graph: automation.graph,
      lastOutputs: automation.parts.mapValues { Set($0.lastOutput.map(\.id)) },
      proposed: { proposed.contains($0) }, now: now())
    let take = AutomationInbox.take(
      by: node, from: rows.filter { $0.seq <= trigger.mark }, in: context)
    guard !take.taken.isEmpty else {
      try? store.discard(take.dropped, of: trigger.part, in: trigger.automationId)
      return end(trigger)
    }
    pass(trigger, take: take)
  }

  /// 部品の 1 回。役割の入力を組み、`AutomationPartPass` に任せ、終わったら確定する。入力を組めなければ（取った行を DB から
  /// 読めない・読む前に消えた）ログに残して契機を終える。
  private func pass(_ trigger: Trigger, take: AutomationInbox.Take?) {
    guard let automation = store.automation(trigger.automationId),
      let node = automation.graph.node(trigger.part)
    else { return end(trigger) }
    let input: AutomationPartPass.Input
    do throws(AutomationError) {
      guard let built = try self.input(node, automation, take) else {
        NSLog("[automation] the rows part \(trigger.part) took are gone or unreadable")
        return end(trigger)
      }
      input = built
    } catch {
      NSLog("[automation] cannot start part \(trigger.part): \(error)")
      return end(trigger)
    }
    let startedAt = now()
    trigger.lastStart = startedAt
    let pass = AutomationPartPass(run: run, now: now, calendar: calendar)
    trigger.current = pass.start(node, input) { [weak self] outcome in
      guard let self, !trigger.cancelled else { return }
      ended(trigger, take, startedAt, outcome)
    }
  }

  private func ended(
    _ trigger: Trigger, _ take: AutomationInbox.Take?, _ startedAt: Date,
    _ outcome: AutomationPartPass.Outcome
  ) {
    let passEnd = AutomationPassEnd(
      automationId: trigger.automationId, part: trigger.part, trigger: trigger.kind,
      startedAt: startedAt, endedAt: now(), take: take, outcome: outcome)
    let result: AutomationRecorded
    do throws(AutomationError) {
      result = try store.record(passEnd)
    } catch {
      NSLog("[automation] dropped the result of part \(trigger.part): \(error)")
      return end(trigger)
    }
    recorded(trigger.automationId, trigger.part)
    for part in result.grew { wake(trigger.automationId, part) }
    guard !result.failed, take != nil else { return end(trigger) }
    takeNext(trigger)
  }

  /// 契機を終える。番人へ返す数え始めは最後の回の始まり（回が無ければ契機の始まり）。終えた後に、「届いたら」の部品なら
  /// 走っている間に届いた行を起こす決まりを見て、そうでなければ下流をやり直す。一巡へはその後に知らせる——「届いたら」の
  /// 部品が普段の決まりで起き直さなかったことを見てから終わりと数えるため。
  private func end(_ trigger: Trigger) {
    let anchor = trigger.lastStart ?? trigger.startedAt
    anchors[Self.key(trigger.automationId, trigger.part)] = anchor
    trigger.finish(anchor)
    guard let node = store.automation(trigger.automationId)?.graph.node(trigger.part) else {
      return
    }
    if node.part.trigger == .arrival {
      wake(trigger.automationId, trigger.part)
    } else {
      retry(below: trigger.part, in: trigger.automationId)
    }
    flowEnded(trigger)
  }

  private func flowEnded(_ trigger: Trigger) {
    let id = trigger.automationId
    guard var flow = flows[id] else { return }
    let wake = flow.ended(trigger.part, marked: trigger.flowed) { isRunning(id, $0) }
    flows[id] = flow.finished ? nil : flow
    for part in wake { scheduler.runNow(id: Self.key(id, part)) }
  }
}
