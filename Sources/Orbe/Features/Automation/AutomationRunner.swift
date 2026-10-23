import Foundation
import Observation

/// 自動化の部品を 1 つずつ番人に載せ、部品の契機ごとに「上流から読む → 部品の 1 回 → 確定」を回す。main で使う。
///
/// 番人の鍵は `automation:<id>/<部品の ID>`（鍵を変えても同じ部品のまま）。間隔・cron の部品は止めていなければ「いつ」付きで、
/// それ以外（手動・届いたら・止めた自動化の部品）は「いつ」なしで載せる。同じ部品の契機は重ならない（重ねない保証・
/// 「今すぐ」・走っているかは番人が持つ）。1 つの契機は、契機の始まりの時点の上流の行（つながりごと表ごとの上流の最後の番号
/// まで）を読み、読めば取る行を全部取って 1 回だけ回す。
///
/// 「届いたら」の部品を起こす決まりは `AutomationRunner+Wake`。
///
/// 流す（`flow`）は、部品を指してそこに至る道の上の部品を 1 回ずつ回す（`AutomationFlow`）。一巡は自動化ごとに高々 1 つで、
/// メモリだけに持つ。走らせ役は契機の始まりと終わりを一巡へ知らせ、返った部品を「今すぐ」で起こす。道の上の部品を番人から
/// 外すと一巡を打ち切る——待っている回の終わりが来なくなるので。一巡が終わるか打ち切られたら `flowEnded` で知らせる。観測に
/// 載せるのは一巡だけで（画面が一巡の有無を読む）、他の持ち物は部品の回のたびに変わるので観測から外す。
///
/// 部品の回を記録するたびに `recorded` で、その回の終わり（読んだもの・部品の 1 回の結果）と確定を知らせる（知らせるか
/// どうか・何を出すかは受けた側が決める）。`recorded` は確定の直後、下流を起こす前に同期で呼ぶ——受けた側はその中で、確定した
/// 回が出した行を読み、下流が読む前に手を掛けられる（試走の `limit` がこの順に依る）。定義を書いたら `defined`、消したら
/// `deleted` で知らせる。使い手が差し替えられるのは、番人に載せる部品（`admits`。既定は全部品）と知らせだけ。
@Observable final class AutomationRunner {
  let store: AutomationStore
  @ObservationIgnored var now: () -> Date = Date.init
  @ObservationIgnored var calendar: () -> Calendar = { Calendar.current }

  /// 番人（一巡が部品を起こす）。
  let scheduler: BackgroundScheduler
  let run: BackgroundScheduler.Run
  /// 行を見る agent に、その回の行を Orbe の MCP で渡す帳面（試走の走らせ役も同じものを使う）。
  let runSessions: AutomationRunSessions
  let workspaces: () -> AutomationWorkspaces
  private let recorded: (AutomationPassRecord) -> Void
  private let defined: (Int) -> Void
  private let deleted: (Int) -> Void
  private let admits: (Int, AutomationPartID) -> Bool
  private let flowEnded: (Int, AutomationFlow) -> Void
  /// 番人に載せている鍵。
  @ObservationIgnored private var registered = Set<String>()
  /// 部品ごとの、前の契機の始まりの時点の、入力ごとの上流の最後の番号（メモリだけ。無ければ読んだ位置だけが基準線）。
  @ObservationIgnored var marks: [String: [AutomationPartID: AutomationSeqs]] = [:]
  /// 部品ごとの、番人に最後に返した数え始め。記録の無い契機（取る行が 0 件）でも進むので、次の時刻はこれから数える。
  @ObservationIgnored private var anchors: [String: Date] = [:]
  /// 走っている契機（掃除から守る行を言う）。
  @ObservationIgnored private var active: [ObjectIdentifier: Trigger] = [:]
  /// 読めば取る行の数え直し（古さの上限を過ぎた行を除く）の時刻と、その時計。
  @ObservationIgnored var recountAt: Date?
  @ObservationIgnored var recountTimer: Timer?
  /// 自動化ごとの、流している途中の一巡（置くのは `flow`）。
  var flows: [Int: AutomationFlow] = [:]

  /// `workspaces` はタスク候補の付け先にできる今の workspace。判定の部品にだけ渡す。`admits` は自動化の ID と部品の ID から、
  /// 番人に載せるかを決める。
  init(
    store: AutomationStore, scheduler: BackgroundScheduler = BackgroundScheduler(),
    run: @escaping BackgroundScheduler.Run = { BackgroundRuns.shared.run($0, completion: $1) },
    runSessions: AutomationRunSessions = AutomationRunSessions(),
    workspaces: @escaping () -> AutomationWorkspaces,
    recorded: @escaping (AutomationPassRecord) -> Void, defined: @escaping (Int) -> Void,
    deleted: @escaping (Int) -> Void,
    admits: @escaping (Int, AutomationPartID) -> Bool = { _, _ in true },
    flowEnded: @escaping (Int, AutomationFlow) -> Void = { _, _ in }
  ) {
    self.store = store
    self.scheduler = scheduler
    self.run = run
    self.runSessions = runSessions
    self.workspaces = workspaces
    self.recorded = recorded
    self.defined = defined
    self.deleted = deleted
    self.admits = admits
    self.flowEnded = flowEnded
    store.onUnavailable = { [weak self] in self?.stopAll() }
    store.holding = { [weak self] in
      Set(self?.active.values.flatMap { $0.holding } ?? [])
    }
    store.committed = { [weak self] in self?.scheduleRecount() }
  }

  /// 起動時に一度、全部品を番人へ載せ、止めていない自動化の「届いたら」の部品に起こす決まりを見る（過ぎていた間隔の回は
  /// ここで 1 回だけ走る）。
  func start() {
    for automation in store.automations { register(automation) }
    scheduleRecount()
  }

  /// どれかの部品が走っているか。
  func isRunning(_ id: Int) -> Bool {
    store.automation(id)?.graph.nodes.contains { isRunning(id, $0.id) } ?? false
  }

  func isRunning(_ id: Int, _ part: AutomationPartID) -> Bool {
    scheduler.isRunning(id: Self.key(id, part))
  }

  /// `now`（渡さなければ走らせ役の今）から見て、どれかの部品が次に予定で回る時刻（止めていれば nil）。
  func nextRunAt(_ automation: Automation, now: Date? = nil) -> Date? {
    automation.graph.nodes.compactMap { nextRunAt(automation, part: $0.id, now: now) }.min()
  }

  /// 部品が次に予定で回る時刻。止めている・予定の無い部品は nil。過ぎていれば `now` 以前の時刻を返す。
  func nextRunAt(_ automation: Automation, part: AutomationPartID, now: Date? = nil) -> Date? {
    guard !automation.paused, let node = automation.graph.node(part),
      case .scheduled(let timing) = node.part.trigger
    else { return nil }
    let anchor = anchors[Self.key(automation.id, part)] ?? automation.state(part).anchor
    switch timing.next(after: anchor, deadline: nil, now: now ?? self.now(), calendar: calendar()) {
    case .run(let date): return date
    case .expire: return nil
    }
  }

  // MARK: - 定義の変異

  /// `id` が nil なら作り、あれば `version` を添えて書き換える。何をするかが変わった部品は走っている回を止めて載せ直し（結果は
  /// 捨てる）、外した部品は外し、足した部品は足した時刻から数える。鍵・名前・予定・件数の上限・通知だけなら予定だけを
  /// 差し替える（走っている回は最後まで走る）。
  func set(_ id: Int?, version: Int? = nil, _ definition: AutomationDefinition)
    throws(AutomationError) -> Automation
  {
    try checkAvailable()
    guard let id else {
      let automation = try store.create(definition, now: now())
      register(automation)
      defined(automation.id)
      return automation
    }
    let replaced = try store.replace(id, version: version, with: definition, now: now())
    let automation = replaced.automation
    for part in replaced.removed + replaced.reworked { unregister(id, part) }
    register(automation)
    defined(id)
    return automation
  }

  /// 止めるのは時刻による予定と起動時の起こしだけ。走っている回は止めない。再開したら起こす決まりを見る。
  func pause(_ id: Int, _ paused: Bool) throws(AutomationError) -> Automation {
    try checkAvailable()
    let automation = try store.setPaused(id, paused, now: now())
    register(automation)
    return automation
  }

  /// 消す。走っている回は止め、その結果は捨てる。
  func delete(_ id: Int) throws(AutomationError) {
    try checkAvailable()
    let parts = store.automation(id)?.graph.nodes.map(\.id) ?? []
    try store.delete(id, now: now())
    for part in parts { unregister(id, part) }
    deleted(id)
  }

  func checkAvailable() throws(AutomationError) {
    guard store.available else { throw store.unavailableError }
  }

  // MARK: - 番人への登録

  static func key(_ id: Int, _ part: AutomationPartID) -> String { "automation:\(id)/\(part)" }

  /// 全部品を番人に合わせる。載っていない部品は載せ（数え始めは部品の最後に回った時刻、無ければ足した時刻）、載っている部品は
  /// 予定だけを差し替える。止めていなければ「届いたら」の部品に起こす決まりを見る。
  private func register(_ automation: Automation) {
    let id = automation.id
    for node in automation.graph.nodes where admits(id, node.id) {
      let key = Self.key(id, node.id)
      var timing: BackgroundTiming?
      if !automation.paused, case .scheduled(let scheduled) = node.part.trigger {
        timing = scheduled
      }
      if registered.contains(key) {
        try? scheduler.retime(id: key, timing: timing)
        continue
      }
      let part = node.id
      let start: BackgroundScheduler.Start = { [weak self] trigger, finish in
        self?.begin(id, part, trigger, finish) ?? BackgroundRunHandle {}
      }
      try? scheduler.register(
        id: key, timing: timing, anchor: automation.state(part).anchor, start: start)
      registered.insert(key)
    }
    guard !automation.paused else { return }
    for node in automation.graph.nodes { wake(id, node.id) }
  }

  /// 外す。走っている回は止め、その結果は捨てる。起こす決まりの印と数え始めも忘れ、この部品を道に含む一巡を打ち切る。
  private func unregister(_ id: Int, _ part: AutomationPartID) {
    let key = Self.key(id, part)
    if let flow = flows[id], flow.path.contains(part) {
      flows[id] = nil
      flowEnded(id, flow)
    }
    scheduler.remove(id: key)
    registered.remove(key)
    marks[key] = nil
    anchors[key] = nil
  }

  /// 全部品を番人から外す（走っている回は止め、その結果は捨てる）。一巡は打ち切る。
  func stopAll() {
    let cut = flows
    flows = [:]
    for (id, flow) in cut { flowEnded(id, flow) }
    for key in registered { scheduler.remove(id: key) }
    registered = []
    marks = [:]
    anchors = [:]
    active = [:]
    recountTimer?.invalidate()
    recountTimer = nil
    recountAt = nil
  }
}

/// 部品の契機。
extension AutomationRunner {
  /// 走っている契機。止められたら、以後の結果は捨てる。
  private final class Trigger {
    let automationId: Int
    let part: AutomationPartID
    let kind: AutomationPartRun.Trigger
    let startedAt: Date
    let finish: (Date) -> Void
    /// 契機の始まりの時点の、入力ごとの上流の最後の番号。これ以下の行を読む。
    var baseline: [AutomationPartID: AutomationSeqs] = [:]
    /// 走っている回が読んだ行とその出どころ。
    var holding: [AutomationRowRef] = []
    /// 回の始まり。
    var passStartedAt: Date?
    var current: BackgroundRunHandle?
    var cancelled = false
    /// 一巡の分として受け取った契機か。
    let flowed: Bool

    init(
      automationId: Int, part: AutomationPartID, kind: AutomationPartRun.Trigger,
      startedAt: Date, finish: @escaping (Date) -> Void, flowed: Bool
    ) {
      self.automationId = automationId
      self.part = part
      self.kind = kind
      self.startedAt = startedAt
      self.finish = finish
      self.flowed = flowed
    }
  }

  private func begin(
    _ id: Int, _ part: AutomationPartID, _ kind: BackgroundScheduler.Trigger,
    _ finish: @escaping (Date) -> Void
  ) -> BackgroundRunHandle {
    // 番人の上に「走っている」を残さないよう、部品が無ければ契機はすぐ終わったものとして知らせる。
    guard let automation = store.automation(id), let node = automation.graph.node(part) else {
      finish(now())
      return BackgroundRunHandle {}
    }
    // 一巡があるときだけ触れる（触れるだけで観測が切れ、流していない自動化の回のたびに画面が描き直される）。
    var flowed = false
    if var flow = flows[id] {
      flowed = flow.started(part, in: automation.graph)
      flows[id] = flow
    }
    // 流しが起こした回でない「届いたら」の部品の回は、起こす決まりが起こした（届いた行で起きた）回。
    let trigger = Trigger(
      automationId: id, part: part,
      kind: node.part.trigger == .arrival && !flowed ? .arrival : kind == .now ? .now : .schedule,
      startedAt: now(), finish: finish, flowed: flowed)
    active[ObjectIdentifier(trigger)] = trigger
    if node.inputs.isEmpty {
      pass(trigger, read: nil)
    } else if let inlets = inlets(of: part) {
      let marks = inlets.mapValues(\.up)
      self.marks[Self.key(id, part)] = marks
      trigger.baseline = marks
      read(trigger)
    } else {
      end(trigger)
    }
    return BackgroundRunHandle { [weak self] in
      trigger.cancelled = true
      trigger.current?.stop()
      self?.active[ObjectIdentifier(trigger)] = nil
    }
  }

  /// 契機の始まりの時点までの上流の行を読む。取る行が 0 件なら手段を起こさず、読んだ位置を読む上限の番号まで進めて終える。
  /// ただし今の集合の処理は 0 件でも回す（空の集合を写す）。
  private func read(_ trigger: Trigger) {
    let read: AutomationIntake.Read?
    do throws(AutomationError) {
      read = try store.read(
        trigger.part, of: trigger.automationId, baseline: trigger.baseline, now: now())
    } catch {
      NSLog("[automation] cannot read the rows of part \(trigger.part): \(error)")
      return end(trigger)
    }
    guard let read, let node = store.automation(trigger.automationId)?.graph.node(trigger.part)
    else { return end(trigger) }
    guard !read.taken.isEmpty || (node.role == .process && node.coverage == .currentSet) else {
      try? store.discard(read, of: trigger.part, in: trigger.automationId, now: now())
      return end(trigger)
    }
    pass(trigger, read: read)
  }

  /// 部品の 1 回。役割の入力を組み、`AutomationPartPass` に任せ、終わったら確定する。
  private func pass(_ trigger: Trigger, read: AutomationIntake.Read?) {
    guard let automation = store.automation(trigger.automationId),
      let node = automation.graph.node(trigger.part)
    else { return end(trigger) }
    let input = self.input(node, automation, read)
    let startedAt = now()
    trigger.passStartedAt = startedAt
    trigger.holding =
      read.map {
        $0.taken.map(\.ref) + $0.dropped.map(\.row.ref) + $0.taken.compactMap(\.origin?.row)
      } ?? []
    let defId = node.part.defId
    let pass = AutomationPartPass(run: run, now: now, calendar: calendar, runSessions: runSessions)
    trigger.current = pass.start(node, input) { [weak self] outcome in
      guard let self, !trigger.cancelled else { return }
      ended(trigger, defId, read, startedAt, outcome)
    }
  }

  private func ended(
    _ trigger: Trigger, _ defId: AutomationDefID, _ read: AutomationIntake.Read?,
    _ startedAt: Date, _ outcome: AutomationPartPass.Outcome
  ) {
    let passEnd = AutomationPassEnd(
      automationId: trigger.automationId, part: trigger.part, defId: defId,
      trigger: trigger.kind, startedAt: startedAt, endedAt: now(), read: read, outcome: outcome)
    let result: AutomationRecorded
    do throws(AutomationError) {
      result = try store.record(passEnd)
    } catch {
      NSLog("[automation] dropped the result of part \(trigger.part): \(error)")
      return end(trigger)
    }
    trigger.holding = []
    recorded(AutomationPassRecord(end: passEnd, run: result.run))
    if result.changed, let automation = store.automation(trigger.automationId) {
      for node in automation.graph.downstream(of: trigger.part) {
        wake(trigger.automationId, node.id)
      }
    }
    end(trigger)
  }

  /// 契機を終える。番人へ返す数え始めは回の始まり（回が無ければ契機の始まり）。終えた後に、「届いたら」の部品なら
  /// 走っている間に届いた行を起こす決まりを見て、そうでなければ下流をやり直す。一巡へはその後に知らせる——「届いたら」の
  /// 部品が普段の決まりで起き直さなかったことを見てから終わりと数えるため。
  private func end(_ trigger: Trigger) {
    active[ObjectIdentifier(trigger)] = nil
    let key = Self.key(trigger.automationId, trigger.part)
    let anchor = trigger.passStartedAt ?? trigger.startedAt
    anchors[key] = anchor
    trigger.finish(anchor)
    guard let node = store.automation(trigger.automationId)?.graph.node(trigger.part) else {
      return
    }
    if node.part.trigger == .arrival {
      wake(trigger.automationId, trigger.part)
    } else {
      retry(below: trigger.part, in: trigger.automationId)
    }
    advanceFlow(after: trigger)
  }

  private func advanceFlow(after trigger: Trigger) {
    let id = trigger.automationId
    guard var flow = flows[id], let graph = store.automation(id)?.graph else { return }
    let wake = flow.ended(trigger.part, flowed: trigger.flowed, in: graph) { isRunning(id, $0) }
    flows[id] = flow.finished ? nil : flow
    if flow.finished { flowEnded(id, flow) }
    for part in wake { scheduler.runNow(id: Self.key(id, part)) }
  }
}
