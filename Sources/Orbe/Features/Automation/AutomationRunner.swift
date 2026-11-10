import Foundation
import Observation

/// 自動化のノードを 1 つずつ番人に載せ、ノードの契機ごとに「上流から読む → ノードの 1 回 → 確定」を回す。main で使う。
///
/// 番人の鍵は `automation:<id>/<ノードの ID>`（鍵を変えても同じノードのまま）。間隔・cron のノードは実効で止めていなければ
/// 「いつ」付きで、それ以外（手動・届いたら・実効で止めたノード）は「いつ」なしで載せる。同じノードの契機は重ならない（重ねない
/// 保証・「今すぐ」・走っているかは番人が持つ）。1 つの契機は、契機の始まりの時点の上流の行（つながりごと表ごとの上流の最後の
/// 番号まで）を読み、読めば取る行を全部取って 1 回だけ回す。
///
/// 止める（自動化かノード）は、Orbe が自分から動かすことだけを止める: 実効で止めたノード（`Automation.halted`）は予定の時刻でも
/// 起こす決まり（`AutomationRunner+Wake`）でも動かず、未処理は積もる。走っている回と明示の実行（流し）は止めない。
///
/// 流す（`flow`）は、ノードを指してそこに至る道の上のノードを 1 回ずつ回す（`AutomationFlow`）。一巡は自動化ごとに複数あってよく、
/// 同じ自動化の一巡の道は互いに交わらない（交わる流しは断る）ので、ノードを通る一巡は高々 1 つ。一巡はメモリだけに持つ。走らせ役は
/// 契機の始まりと終わりをそのノードを通る一巡へ知らせ、返ったノードを「今すぐ」で起こす。道の上のノードを番人から外すと、その
/// ノードを通る一巡を打ち切る——待っている回の終わりが来なくなるので。一巡が終わるか打ち切られたら `flowEnded` で知らせる。観測に
/// 載せるのは一巡だけで（画面が一巡の有無を読む）、他の持ち物はノードの回のたびに変わるので観測から外す。
///
/// ノードの回を記録するたびに `recorded` で、その回の終わり（読んだもの・ノードの 1 回の結果）と確定を知らせる（知らせるか
/// どうか・何を出すかは受けた側が決める）。`recorded` は確定の直後、下流を起こす前に同期で呼ぶ——受けた側はその中で、確定した
/// 回が出した行を読み、下流が読む前に手を掛けられる（試走の `limit` がこの順に依る）。契機が終わるたびに、起こす決まりと一巡の
/// 進みを見た後で `triggerEnded` で知らせる。定義を書いたら `defined` で外したノードと、消したら `deleted` で消えたノードと共に
/// 知らせる。使い手が差し替えられるのは、番人に載せるノード（`admits`。既定は全ノード）と知らせだけ。起こす決まりが番人に載せて
/// いないノードを起こしたら、手段を起こさず `wokeUnadmitted` で知らせる（そのノードをどう扱うかは使い手が決める）。
@Observable final class AutomationRunner {
  let store: AutomationStore
  @ObservationIgnored var now: () -> Date = Date.init
  @ObservationIgnored var calendar: () -> Calendar = { Calendar.current }

  /// 番人（一巡がノードを起こす）。
  let scheduler: BackgroundScheduler
  let run: BackgroundScheduler.Run
  /// 行を見る agent に、その回の行を Orbe の MCP で渡す帳面（試走の走らせ役も同じものを使う）。
  let runSessions: AutomationRunSessions
  let workspaces: () -> AutomationWorkspaces
  private let recorded: (AutomationPassRecord) -> Void
  private let defined: (Int, [AutomationNodeID]) -> Void
  private let deleted: (Int, [AutomationNodeID]) -> Void
  private let admits: (Int, AutomationNodeID) -> Bool
  private let flowEnded: (Int, AutomationFlow) -> Void
  private let triggerEnded: (Int, AutomationNodeID) -> Void
  private let wokeUnadmitted: (Int, AutomationNodeID, [AutomationNodeID: AutomationSeqs]) -> Void
  /// 番人に載せている鍵。
  @ObservationIgnored private var registered = Set<String>()
  /// ノードごとの、前の契機の始まりの時点の、入力ごとの上流の最後の番号（メモリだけ。無ければ読んだ位置だけが基準線）。
  @ObservationIgnored var marks: [String: [AutomationNodeID: AutomationSeqs]] = [:]
  /// ノードごとの、番人に最後に返した数え始め。記録の無い契機（取る行が 0 件）でも進むので、次の時刻はこれから数える。
  @ObservationIgnored var anchors: [String: Date] = [:]
  /// 走っている契機（掃除から守る行を言う）。
  @ObservationIgnored private var active: [ObjectIdentifier: Trigger] = [:]
  /// 読めば取る行の数え直し（古さの上限を過ぎた行を除く）の時刻と、その時計。
  @ObservationIgnored var recountAt: Date?
  @ObservationIgnored var recountTimer: Timer?
  /// 自動化ごとの、流している途中の一巡（置くのは `flow`。道は互いに交わらない）。
  var flows: [Int: [AutomationFlow]] = [:]

  /// `workspaces` は今の workspace の写しの読み口（判定に見せる付け先と、コマンドの走る場所を引く）。`admits` は自動化の ID と
  /// ノードの ID から、番人に載せるかを決める。`wokeUnadmitted` は起こす決まりが起こした、番人に載せていないノードと、その契機の
  /// 基準線（前の契機の印にした、その時点の上流の最後の番号）。
  init(
    store: AutomationStore, scheduler: BackgroundScheduler = BackgroundScheduler(),
    run: @escaping BackgroundScheduler.Run = { BackgroundRuns.shared.run($0, completion: $1) },
    runSessions: AutomationRunSessions = AutomationRunSessions(),
    workspaces: @escaping () -> AutomationWorkspaces,
    recorded: @escaping (AutomationPassRecord) -> Void,
    defined: @escaping (Int, [AutomationNodeID]) -> Void,
    deleted: @escaping (Int, [AutomationNodeID]) -> Void,
    admits: @escaping (Int, AutomationNodeID) -> Bool = { _, _ in true },
    flowEnded: @escaping (Int, AutomationFlow) -> Void = { _, _ in },
    triggerEnded: @escaping (Int, AutomationNodeID) -> Void = { _, _ in },
    wokeUnadmitted: @escaping (Int, AutomationNodeID, [AutomationNodeID: AutomationSeqs]) -> Void =
      { _, _, _ in }
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
    self.triggerEnded = triggerEnded
    self.wokeUnadmitted = wokeUnadmitted
    store.onUnavailable = { [weak self] in self?.stopAll() }
    store.holding = { [weak self] in
      self?.active.values.reduce(into: AutomationHolding()) { $0.formUnion($1.holding) }
        ?? AutomationHolding()
    }
    store.committed = { [weak self] in self?.scheduleRecount() }
  }

  /// 起動時に一度、全ノードを番人へ載せ、実効で止めていない「届いたら」のノードに起こす決まりを見る（過ぎていた間隔の回はここで 1 回だけ走る）。
  func start() {
    for automation in store.automations { register(automation) }
    scheduleRecount()
  }

  // MARK: - 定義の変異

  /// `id` が nil なら作り、あれば `version` を添えて書き換える（確かめてから掛ける）。
  func set(_ id: Int?, version: Int? = nil, _ definition: AutomationDefinition)
    throws(AutomationError) -> Automation
  {
    try set(try store.check(AutomationStore.Write(id, version: version, definition)))
  }

  /// 確かめた書き込みを掛ける。何をするかが変わったノードは走っている回を止めて載せ直し（結果は捨てる）、外したノードは外し、
  /// 足したノードは足した時刻から数える。鍵・名前・予定・件数の上限・出来事の日数・通知だけなら予定だけを差し替える（走っている回は
  /// 最後まで走る）。
  func set(_ checked: AutomationStore.CheckedWrite) throws(AutomationError) -> Automation {
    try checkAvailable()
    let written = try store.apply(checked, now: now())
    adopt(written)
    return written.automation
  }

  /// ストアに掛けた書き込みに番人を合わせる（`set` の後半。書いた時点の起こす決まりもここで見る）。
  func adopt(_ written: AutomationStore.Written) {
    let id = written.automation.id
    for nodeId in written.removed + written.reworked { unregister(id, nodeId) }
    register(written.automation)
    defined(id, written.removed)
  }

  /// 止める・再開する（`nodeId` があればそのノード自身、無ければ自動化）。止めるのは Orbe が自分から動かすことだけで、走っている回は
  /// 止めない。番人に合わせ直し、再開したノードに起こす決まりを見る（過ぎた間隔の回は 1 回すぐ走る）。
  func pause(_ id: Int, nodeId: AutomationNodeID? = nil, _ paused: Bool) throws(AutomationError)
    -> Automation
  {
    try checkAvailable()
    let automation = try store.setPaused(id, nodeId: nodeId, paused, now: now())
    register(automation)
    return automation
  }

  /// 消す。走っている回は止め、その結果は捨てる。消えたノード（定義を読めない自動化はノードの台帳のノード）を知らせる。
  func delete(_ id: Int) throws(AutomationError) {
    try checkAvailable()
    let nodeIds = try store.delete(id, now: now())
    for nodeId in nodeIds { unregister(id, nodeId) }
    deleted(id, nodeIds)
  }

  func checkAvailable() throws(AutomationError) {
    guard store.available else { throw store.unavailableError }
  }

  // MARK: - 番人への登録

  static func key(_ id: Int, _ nodeId: AutomationNodeID) -> String { "automation:\(id)/\(nodeId)" }

  /// 全ノードを番人に合わせる。載っていないノードは載せ（数え始めは番人に最後に返した数え始め、無ければノードの最後に回った時刻、
  /// それも無ければ足した時刻）、載っているノードは予定だけを差し替える。実効で止めたノードは「いつ」なしで載せる（流しの「今すぐ」
  /// では走れる）。「届いたら」のノードに起こす決まりを見る（決まりが実効で止めたノードを除く）。
  private func register(_ automation: Automation) {
    let id = automation.id
    for node in automation.graph.nodes where admits(id, node.id) {
      let key = Self.key(id, node.id)
      var timing: BackgroundTiming?
      if !automation.halted(node.id), case .scheduled(let scheduled) = node.entity.trigger {
        timing = scheduled
      }
      if registered.contains(key) {
        try? scheduler.retime(id: key, timing: timing)
        continue
      }
      let nodeId = node.id
      let start: BackgroundScheduler.Start = { [weak self] trigger, finish in
        self?.begin(id, nodeId, trigger, finish) ?? BackgroundRunHandle {}
      }
      try? scheduler.register(
        id: key, timing: timing, anchor: anchors[key] ?? automation.state(nodeId).anchor,
        start: start)
      registered.insert(key)
    }
    for node in automation.graph.nodes { wake(id, node.id) }
  }

  /// 外す。走っている回は止め、その結果は捨てる。起こす決まりの印と数え始めも忘れ、このノードを道に含む一巡を打ち切る。
  private func unregister(_ id: Int, _ nodeId: AutomationNodeID) {
    let key = Self.key(id, nodeId)
    if let index = flows[id]?.firstIndex(where: { $0.path.contains(nodeId) }) {
      endFlow(id, at: index)
    }
    scheduler.remove(id: key)
    registered.remove(key)
    marks[key] = nil
    anchors[key] = nil
  }

  /// 起こす。番人に載せていないノードは、契機の始まりと同じくその時点の上流の最後の番号を前の契機の印にしてから、それを基準線に
  /// して `wokeUnadmitted` で知らせる。読めなければ何もしない（ログに残す）。
  func runNow(_ id: Int, _ nodeId: AutomationNodeID) {
    let key = Self.key(id, nodeId)
    guard !registered.contains(key) else { return scheduler.runNow(id: key) }
    guard let inlets = inlets(of: nodeId) else { return }
    let marks = inlets.mapValues(\.up)
    self.marks[key] = marks
    wokeUnadmitted(id, nodeId, marks)
  }

  /// 全ノードを番人から外す（走っている回は止め、その結果は捨てる）。一巡は打ち切る。
  func stopAll() {
    let cut = flows
    flows = [:]
    for (id, list) in cut { list.forEach { flowEnded(id, $0) } }
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

/// ノードの契機。
extension AutomationRunner {
  /// 走っている契機。止められたら、以後の結果は捨てる。
  private final class Trigger {
    let automationId: Int
    let nodeId: AutomationNodeID
    let kind: AutomationNodeRun.Trigger
    let startedAt: Date
    let finish: (Date) -> Void
    /// 契機の始まりの時点の、入力ごとの上流の最後の番号。これ以下の行を読む。
    var baseline: [AutomationNodeID: AutomationSeqs] = [:]
    /// 走っている回が確定まで使うもの。
    var holding = AutomationHolding()
    /// 回の始まり。
    var passStartedAt: Date?
    var current: BackgroundRunHandle?
    var cancelled = false
    /// 一巡の分として受け取った契機か。
    let flowed: Bool

    init(
      automationId: Int, nodeId: AutomationNodeID, kind: AutomationNodeRun.Trigger,
      startedAt: Date, finish: @escaping (Date) -> Void, flowed: Bool
    ) {
      self.automationId = automationId
      self.nodeId = nodeId
      self.kind = kind
      self.startedAt = startedAt
      self.finish = finish
      self.flowed = flowed
    }
  }

  private func begin(
    _ id: Int, _ nodeId: AutomationNodeID, _ kind: BackgroundScheduler.Trigger,
    _ finish: @escaping (Date) -> Void
  ) -> BackgroundRunHandle {
    // 番人の上に「走っている」を残さないよう、ノードが無ければ契機はすぐ終わったものとして知らせる。
    guard let automation = store.automation(id), let node = automation.graph.node(nodeId) else {
      finish(now())
      return BackgroundRunHandle {}
    }
    // ノードを通る一巡があるときだけ触れる（触れるだけで観測が切れ、流していない自動化の回のたびに画面が描き直される）。
    var flowed = false
    if let index = flows[id]?.firstIndex(where: { $0.path.contains(nodeId) }) {
      flowed = flows[id]?[index].started(nodeId, in: automation) ?? false
    }
    // 流しが起こした回でない「届いたら」のノードの回は、起こす決まりが起こした（届いた行で起きた）回。
    let trigger = Trigger(
      automationId: id, nodeId: nodeId,
      kind: node.entity.trigger == .arrival && !flowed ? .arrival : kind == .now ? .now : .schedule,
      startedAt: now(), finish: finish, flowed: flowed)
    active[ObjectIdentifier(trigger)] = trigger
    if node.inputs.isEmpty {
      pass(trigger, read: nil)
    } else if let inlets = inlets(of: nodeId) {
      let marks = inlets.mapValues(\.up)
      self.marks[Self.key(id, nodeId)] = marks
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
        trigger.nodeId, of: trigger.automationId, baseline: trigger.baseline, now: now())
    } catch {
      NSLog("[automation] cannot read the rows of node \(trigger.nodeId): \(error)")
      return end(trigger)
    }
    guard let read, let node = store.automation(trigger.automationId)?.graph.node(trigger.nodeId)
    else { return end(trigger) }
    guard !read.taken.isEmpty || (node.role == .process && node.coverage == .currentSet) else {
      try? store.discard(read, of: trigger.nodeId, in: trigger.automationId, now: now())
      return end(trigger)
    }
    pass(trigger, read: read)
  }

  /// ノードの 1 回。役割の入力を組み、`AutomationNodePass` に任せ、終わったら確定する。
  private func pass(_ trigger: Trigger, read: AutomationIntake.Read?) {
    guard let automation = store.automation(trigger.automationId),
      let node = automation.graph.node(trigger.nodeId)
    else { return end(trigger) }
    let input = self.input(node, automation, read)
    let startedAt = now()
    trigger.passStartedAt = startedAt
    let defId = node.entity.defId
    trigger.holding = AutomationHolding(
      rows: Set(read.map { $0.taken.map(\.ref) + $0.dropped.map(\.row.ref) } ?? []),
      defs: [defId])
    let pass = AutomationNodePass(
      run: run, now: now, calendar: calendar, runSessions: runSessions, workspaces: workspaces)
    trigger.current = pass.start(node, input) { [weak self] outcome in
      guard let self, !trigger.cancelled else { return }
      ended(trigger, defId, read, startedAt, outcome)
    }
  }

  private func ended(
    _ trigger: Trigger, _ defId: AutomationNodeDefID, _ read: AutomationIntake.Read?,
    _ startedAt: Date, _ outcome: AutomationNodePass.Outcome
  ) {
    let passEnd = AutomationPassEnd(
      automationId: trigger.automationId, nodeId: trigger.nodeId, defId: defId,
      trigger: trigger.kind, startedAt: startedAt, endedAt: now(), read: read, outcome: outcome)
    let result: AutomationRecorded
    do throws(AutomationError) {
      result = try store.record(passEnd)
    } catch {
      NSLog("[automation] dropped the result of node \(trigger.nodeId): \(error)")
      return end(trigger)
    }
    trigger.holding = AutomationHolding()
    recorded(AutomationPassRecord(end: passEnd, run: result.run))
    if result.changed, let automation = store.automation(trigger.automationId) {
      for node in automation.graph.downstream(of: trigger.nodeId) {
        wake(trigger.automationId, node.id)
      }
    }
    end(trigger)
  }

  /// 契機を終える。番人へ返す数え始めは回の始まり（回が無ければ契機の始まり）。終えた後に、「届いたら」のノードなら
  /// 走っている間に届いた行を起こす決まりを見て、そうでなければ下流をやり直す。一巡へはその後に知らせる——「届いたら」の
  /// ノードが普段の決まりで起き直さなかったことを見てから終わりと数えるため。
  private func end(_ trigger: Trigger) {
    defer { triggerEnded(trigger.automationId, trigger.nodeId) }
    active[ObjectIdentifier(trigger)] = nil
    let key = Self.key(trigger.automationId, trigger.nodeId)
    let anchor = trigger.passStartedAt ?? trigger.startedAt
    anchors[key] = anchor
    trigger.finish(anchor)
    guard let node = store.automation(trigger.automationId)?.graph.node(trigger.nodeId) else {
      return
    }
    if node.entity.trigger == .arrival {
      wake(trigger.automationId, trigger.nodeId)
    } else {
      retry(below: trigger.nodeId, in: trigger.automationId)
    }
    advanceFlow(after: trigger)
  }

  /// 契機の終わりを、そのノードを通る一巡へ知らせて進める。
  private func advanceFlow(after trigger: Trigger) {
    let id = trigger.automationId
    guard let index = flows[id]?.firstIndex(where: { $0.path.contains(trigger.nodeId) }),
      var flow = flows[id]?[index], let automation = store.automation(id)
    else { return }
    let wake = flow.ended(
      trigger.nodeId, flowed: trigger.flowed,
      covered: covered(trigger.nodeId, of: id, since: trigger.baseline), in: automation
    ) { isRunning(id, $0) }
    flows[id]?[index] = flow
    if flow.finished { endFlow(id, at: index) }
    for nodeId in wake { scheduler.runNow(id: Self.key(id, nodeId)) }
  }

  /// 一巡を列から外し、終わったか打ち切られたことを知らせる。
  private func endFlow(_ id: Int, at index: Int) {
    guard let flow = flows[id]?.remove(at: index) else { return }
    if flows[id]?.isEmpty == true { flows[id] = nil }
    flowEnded(id, flow)
  }
}
