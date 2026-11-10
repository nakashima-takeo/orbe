import Foundation

/// 試走——自動化のノードを、本番を汚さずに本番と同じ流しで動かし、ノードの回ごとの結果を集める 1 回。main で使う。
///
/// 本番の DB を区切ってメモリの DB へ写し（`AutomationStore.Copy`）、写しの上に本番と同じ走らせ役を立てて、範囲の道だけを番人に
/// 載せて流す。写しの走らせ役は、本番の走らせ役が持つ前の契機の印と数え始めを引き継ぐ。読む・確定・出す側の行・起こす決まり・
/// 結果の確かめは本番のコードのまま写しの上で動き、本番の DB には届かない。本番の層は試走を知らない。試走の都合は、試走が
/// 自分の写しに掛ける操作（書く前の定義の書き込み・予定を手動にすること・`AutomationTrial+Copy`・走らせ役を立てる間だけ写しの
/// 自動化を止めること）と、載せるノードの選び方だけで表す:
///
/// - 副作用と仕事は止めるノードで、写しの上でも動かさない（載せない）。起こす決まりが起こしたらその場で、流しが起こすはずの
///   止めるノード（`AutomationFlow` が見届けないもの）は流しの終わりに、本番の読みで取るはずだった行を読んで返し、読んだことにする。
/// - 与えた行は、取得の入口ならその取得の、入力のある入口ならただ 1 つの上流の出力として、写しに新しい行で書く。取得の入口は
///   動かない（載せない）。
/// - `limit` は、道の根の取得の回が写しに確定した直後、受け手が読む前に、その回が足した新しい行のうち N 行を超えた分を写しから
///   取り除いて掛ける（与えた行は書く前に N 行に切る）。
///
/// 写しの上では、流す前に範囲の道のノードの間隔・cron の予定を手動にする——予定の時刻で回さないため。流しの間は自動化を止めない
/// （止めると「届いたら」のノードも起きなくなり、本番の流しと違う動きになる）。一巡は間隔・cron・手動を同じ「普段なら今すぐ動かない
/// ノード」として扱うので、流しの動きは本番と変わらない。止めた印は本番のまま写るので、止めた自動化・止めたノードの試走は、本番で
/// それを流したときと同じに動く。ほかの自動化は写しに残るが番人に載せないので動かない。候補の帳面は、試走する判定自身の候補だけが
/// 効く。流しが終わるか打ち切られたら写しを捨てる。
///
/// 保存した定義は、予定を手動にしてから、写しの自動化を止めた間に走らせ役を立てて流す——本番で流すときは起こす決まりを見直さない
/// ので、立てるときの起こす決まりで道の上の「届いたら」が流しより先に走ると、本番で流したときより回が増えるため。
///
/// 書く前の定義は、写しに書き込みを掛けた後、その書き込みに写しの走らせ役を本番の書き込みと同じに合わせ（`AutomationRunner.adopt`。
/// 本番の予定のまま番人に載せ、全ノードに起こす決まりを、前の契機の印を基準線にして見る）、その直後に予定を手動にする。本番で書いた時点に起きる
/// 回（起こす決まりで起きる「届いたら」・過ぎていた予定の回）と、その確定から続く起こしは写しの上でも同じに起き、それがすべて
/// 終わってから行を与えて流す。続けて流すと、書いた時点の回と流しの回の確定の順が本番と入れ替わりうる（判定の案が、流しの取得に
/// 無効にされた行を指して捨てられる など）。
final class AutomationTrial {
  /// ノードの結果。`atWrite` は本番で書いた時点に起きる分か（書いた時点の起こす決まりと過ぎていた予定の回、その確定から続く起こし）。
  enum Pass: Equatable {
    /// 写しの上で確定した回（本番の `runs` の要素と同じ形）と、その中身。
    case ran(AutomationNodeRun, Content, atWrite: Bool)
    /// 止めた副作用・仕事に渡るはずだった行。
    case held([String], atWrite: Bool)
    /// 与えた行を出力にした取得が下流へ渡す行。
    case given([String])

    var atWrite: Bool {
      switch self {
      case .ran(_, _, let atWrite), .held(_, let atWrite): atWrite
      case .given: false
      }
    }
  }

  enum Content: Equatable {
    case none
    /// 下流へ渡す行（取得・処理）。
    case rows([String])
    /// 候補の案と、対応済みにするリンク（判定）。
    case judged(proposals: [AutomationNodePass.Proposal], resolved: [String])
  }

  /// 試走の ID（起動中だけ。使い回さない）。
  let id: Int
  let target: Target
  let request: Request
  let startedAt: Date
  /// 外の形の範囲。始めたときの定義で解き、写しの上の自動化で解き直す。
  private(set) var keys: Keys
  /// 写しの上の自動化で解いた範囲（写しに書き終えてから）。
  private(set) var range: Range?
  private(set) var endedAt: Date?
  /// 流し切れずに終わった理由（写している間に範囲のノードが消えた・本番の版が進んだ・写しに掛ける操作が書けなかった・写しが
  /// 使えなくなった など）。
  private(set) var failure: String?
  /// ノードごとの回（本番の `runs` と同じく新しい順）。
  private(set) var passes: [AutomationNodeID: [Pass]] = [:]

  private let production: AutomationRunner
  private let onEnd: () -> Void
  private var copy: AutomationStore.Copy?
  /// 写しのストア（写し終えてから終わるまで）。
  private var store: AutomationStore?
  private var runner: AutomationRunner?
  /// 行を与えた取得の入口。
  private var givenFetch: AutomationNodeID?
  /// 終わったときの一巡（打ち切られたものを含む）。
  private var finalFlow: AutomationFlow?
  /// 書いた時点の起こしが静まるのを待っている、行を与えて流す段取り。
  private var waiting: Plan?
  /// 書いた時点の起こしの間か（書き込みに走らせ役を合わせてから、行を与えて流すまで）。
  private var writing = false
  /// 流し切って終えたか（止めるノードを読んだか）。
  private var completed = false
  private var stopped = false

  /// 行を与えて流す段取り: 与えた行と、番人に載せるノードと、流しの行き先。
  private struct Plan {
    let given: Given?
    let admitted: Set<AutomationNodeID>
    let targets: [AutomationNodeID]
  }

  /// `keys` は始めたときの定義で解いた範囲。`production` は本番の走らせ役（ストア・実行の係・時計・workspace を借りる）。`onEnd` は
  /// 終わったときに 1 度だけ呼ぶ。
  init(
    id: Int, target: Target, request: Request, keys: Keys, production: AutomationRunner,
    onEnd: @escaping () -> Void
  ) {
    self.id = id
    self.target = target
    self.request = request
    self.keys = keys
    self.production = production
    self.onEnd = onEnd
    startedAt = production.now()
  }

  var running: Bool { endedAt == nil }

  /// 写している途中か。
  var preparing: Bool { copy != nil }

  /// 範囲を写しの上で解く前（どのノードもまだ動いていない）のノードの進み。
  var unresolvedState: NodeState { running ? .waiting : .untouched }

  /// 打ち切りで終わっても、回または渡るはずだった行を持つノードは動いたものとする（書いた時点の分は流しの成否に依らず本番で起きる）。
  func state(of nodeId: AutomationNodeID) -> NodeState {
    guard let range else { return unresolvedState }
    if nodeId == givenFetch { return .given }
    let moved = passes[nodeId]?.isEmpty == false
    if let node = range.path.first(where: { $0.id == nodeId }), Self.holds(node) {
      if running { return .waiting }
      return completed || moved ? .held : .untouched
    }
    guard running else {
      return finalFlow?.isDone(nodeId) == true || moved ? .done : .untouched
    }
    if runner?.currentFlow(range.automationId, through: nodeId)?.isDone(nodeId) == true {
      return .done
    }
    return runner?.isRunning(range.automationId, nodeId) == true ? .running : .waiting
  }

  /// 止めるノード（副作用・仕事）か。
  private static func holds(_ node: AutomationGraph.Node) -> Bool {
    node.role == .sideEffect || node.role == .work
  }

  // MARK: - 流れ

  /// 写し始める。写しは画面の合間に 1 区切りずつ進める。
  func begin() throws(AutomationError) {
    copy = try production.store.copy()
    stepLater()
  }

  /// 止める。写しも走っている手段も止め、以後は何も集めない。
  func stop() {
    guard !stopped else { return }
    stopped = true
    copy = nil
    store = nil
    let runner = self.runner
    self.runner = nil
    runner?.stopAll()
  }

  private func stepLater() {
    DispatchQueue.main.async { [weak self] in self?.step() }
  }

  private func step() {
    guard !stopped, let copy else { return }
    do throws(AutomationError) {
      guard let store = try copy.step() else { return stepLater() }
      self.copy = nil
      try flow(on: store)
    } catch {
      self.copy = nil
      end(failure: error.message)
    }
  }

  /// 写しの上の流す自動化（書く前の定義なら写しに本番と同じ書き込みを掛けたもの）で範囲を解き直し、止めるノードと行を与えた取得の
  /// 入口を除いた道を番人に載せる走らせ役を立て、書いた時点の起こしが静まってから、行を与えて流す。行き先は、範囲の行き先のうち
  /// 載せるノードと、止めるノードの上流で載せるノード。載せるノードが無ければ流さずに終える。
  private func flow(on store: AutomationStore) throws(AutomationError) {
    let (automation, written) = try target.automation(on: store, now: production.now())
    let id = automation.id
    let nodes = automation.graph.nodes
    let shape = Shape(nodes: automation.graph.checked, automationId: target.savedAutomationId)
    let span = try Self.span(of: shape, request)
    let range = Range(
      automationId: id, to: span.to.map { nodes[$0].id }, path: span.path.map { nodes[$0] })
    keys = Keys(span, of: shape)
    self.range = range
    var given: Given?
    if let rows = request.rows { given = try Self.given(rows, in: span, of: shape) }
    self.store = store
    if let given, given.fetched { givenFetch = nodes[given.entry].id }
    let path = Set(range.path.map(\.id))
    let held = range.path.filter(Self.holds)
    let admitted = path.subtracting(held.map(\.id)).subtracting([givenFetch].compactMap { $0 })
    let targets = range.path.map(\.id).filter { nodeId in
      admitted.contains(nodeId)
        && (range.to.contains(nodeId) || held.contains { $0.inputNodeIds.contains(nodeId) })
    }
    let runner = AutomationRunner(
      store: store, scheduler: Self.scheduler(like: production.scheduler), run: production.run,
      runSessions: production.runSessions, workspaces: production.workspaces,
      recorded: { [weak self] in self?.recorded($0) }, defined: { _, _ in },
      deleted: { _, _ in },
      admits: { $0 == id && admitted.contains($1) },
      flowEnded: { [weak self] _, flow in self?.flowEnded(flow) },
      triggerEnded: { [weak self] _, _ in self?.triggerEnded() },
      wokeUnadmitted: { [weak self] _, nodeId, baseline in self?.woke(nodeId, since: baseline) })
    runner.now = production.now
    runner.calendar = production.calendar
    endWhenUnavailable(store)
    if let owner = target.owner { runner.inherit(owner, from: production) }
    self.runner = runner
    if let written {
      // 予定を手動にするのは書き込みに合わせた後——本番で書いた時点に過ぎていた予定の回は、番人に載せた時点で起きるため。
      writing = true
      runner.adopt(written)
      if let definition = Self.unscheduled(path, of: written.automation) {
        _ = try runner.set(id, version: written.automation.version, definition)
      }
    } else {
      if let definition = Self.unscheduled(path, of: automation) {
        _ = try store.replace(
          id, version: automation.version, with: definition, now: production.now())
      }
      let unpaused = store.automation(id)?.paused == false
      if unpaused { _ = try store.setPaused(id, true, now: production.now()) }
      runner.start()
      if unpaused { _ = try store.setPaused(id, false, now: production.now()) }
    }
    let plan = Plan(given: given, admitted: admitted, targets: targets)
    guard runner.isRunning(id) else { return try proceed(plan) }
    waiting = plan
  }

  /// 写しのストアが使えなくなったら（運転中の壊れ）、写しの走らせ役が全ノードを番人から外す前に、その理由で終える——外した後は、
  /// 書いた時点の回の終わりを待っていても知らせが来ない。走らせ役を立てた後に呼ぶ（走らせ役の止め方を残して前に足す）。
  private func endWhenUnavailable(_ store: AutomationStore) {
    let stopRunner = store.onUnavailable
    store.onUnavailable = { [weak self, weak store] in
      if let self, let store, !stopped, running { end(failure: store.unavailableError.message) }
      stopRunner()
    }
  }

  /// 起こす決まりが、番人に載せていないノードを起こした。道の上の止めるノードなら、その場で渡るはずだった行を読む。
  private func woke(_ nodeId: AutomationNodeID, since baseline: [AutomationNodeID: AutomationSeqs])
  {
    guard !stopped, running, let node = range?.path.first(where: { $0.id == nodeId }),
      Self.holds(node)
    else { return }
    do throws(AutomationError) {
      try hold(node, baseline: baseline)
    } catch {
      end(failure: error.message)
    }
  }

  /// 止めるノードが取る行を、手段を起こさずに渡るはずだった行にし、読んだことにする（読んだ位置を読む上限の番号まで進める）。
  /// 本番では、そのとき起きた副作用・仕事がその行を受け取るので、後の起こしで読み直さない。`baseline` は読む上限の番号（nil なら
  /// 今の上流の最後まで）。
  private func hold(_ node: AutomationGraph.Node, baseline: [AutomationNodeID: AutomationSeqs]?)
    throws(AutomationError)
  {
    guard let store, let range,
      let read = try store.read(
        node.id, of: range.automationId, baseline: baseline, now: production.now())
    else { return }
    if !read.taken.isEmpty {
      passes[node.id, default: []].insert(
        .held(read.taken.map(\.text), atWrite: writing), at: 0)
    }
    try store.consume(read, of: node.id, in: range.automationId, now: production.now())
  }

  /// 契機の終わり。書いた時点の起こしを待っていて、写しの自動化のどのノードも走っていなければ、行を与えて流す。
  private func triggerEnded() {
    guard !stopped, running, let plan = waiting, let range,
      runner?.isRunning(range.automationId) == false
    else { return }
    waiting = nil
    do throws(AutomationError) {
      try proceed(plan)
    } catch {
      end(failure: error.message)
    }
  }

  /// 行を与えて流す。
  private func proceed(_ plan: Plan) throws(AutomationError) {
    writing = false
    guard let store, let range, let runner else { return }
    let id = range.automationId
    if let given = plan.given, let automation = store.automation(id) {
      let nodes = automation.graph.nodes
      let (entry, writer) = (nodes[given.entry].id, nodes[given.writer].id)
      let rows = request.limit.map { Array(given.rows.prefix($0)) } ?? given.rows
      try store.give(rows, as: writer, of: id, at: production.now())
      if given.fetched {
        let given = try store.latestRows(of: entry, in: id, count: rows.count)
        passes[entry] = [.given(given)]
      }
      // 与えた行は書くノードの出力なので、本番の確定の後と同じく、道の上の下流の止めるノードに起こす決まりを見る（載せるノードは
      // 流しが起こす）。
      for node in automation.graph.downstream(of: writer)
      where Self.holds(node) && range.path.contains(where: { $0.id == node.id }) {
        runner.wake(id, node.id)
      }
    }
    guard !plan.targets.isEmpty else { return finish(completed: true) }
    try runner.flow(id, through: plan.admitted, to: plan.targets)
  }

  /// ノードの回の知らせ（確定の直後、下流が読む前）。取得・処理はその回が写しに足した新しい行を結果にし、道の根の取得なら先に
  /// `limit` で写しを絞る。判定は案を結果にする。
  private func recorded(_ record: AutomationPassRecord) {
    let nodeId = record.end.nodeId
    guard !stopped, let store, let range, let run = record.run,
      let node = range.path.first(where: { $0.id == nodeId })
    else { return }
    let content: Content
    do throws(AutomationError) {
      content = try self.content(of: node, run, record.end.outcome, in: range, store)
    } catch {
      return end(failure: error.message)
    }
    passes[nodeId, default: []].insert(.ran(run, content, atWrite: writing), at: 0)
  }

  private func content(
    of node: AutomationGraph.Node, _ run: AutomationNodeRun,
    _ outcome: AutomationNodePass.Outcome, in range: Range, _ store: AutomationStore
  ) throws(AutomationError) -> Content {
    guard !run.failed else { return .none }
    switch run.result {
    case .fetch(let fresh, _), .process(let fresh, _):
      var count = fresh
      if node.role == .fetch, let limit = request.limit, count > limit,
        range.roots.contains(where: { $0.id == node.id })
      {
        try store.trim(
          node.id, in: range.automationId, fresh: fresh, keeping: limit, now: production.now())
        count = limit
      }
      return .rows(try store.latestRows(of: node.id, in: range.automationId, count: count))
    case .judge:
      guard case .succeeded(.judge(let proposals, let resolved), _, _) = outcome else {
        return .none
      }
      return .judged(proposals: proposals, resolved: resolved)
    case .report, .sideEffect, .work, nil:
      return .none
    }
  }

  private func flowEnded(_ flow: AutomationFlow) {
    guard !stopped, running else { return }
    finalFlow = flow
    finish(completed: flow.finished)
  }

  /// 流しの終わり。流し切ったら、流しが起こすはずの止めるノード（一巡が見届けないもの。道の根か、「届いたら」でないか、実効で止めたノード）ごとに、
  /// 本番の読みで取るはずだった行を読み、あれば結果に足す。一巡が見届ける止めるノードは、起こす決まりが起こしたときに読んでいる。
  private func finish(completed: Bool) {
    if completed, let store, let range, let automation = store.automation(range.automationId) {
      let roots = Set(range.roots.map(\.id))
      do throws(AutomationError) {
        for node in range.path
        where Self.holds(node) && !AutomationFlow.watches(node, roots: roots, in: automation) {
          try hold(node, baseline: nil)
        }
      } catch {
        return end(failure: error.message)
      }
    }
    self.completed = completed
    end(failure: nil)
  }

  private func end(failure: String?) {
    self.failure = failure
    endedAt = production.now()
    store = nil
    let runner = self.runner
    self.runner = nil
    // 走らせ役の知らせの中から呼ばれうるので、番人から外すのは知らせを返した後にする。外すのは、終わった後に起き直したノードの
    // 手段を止めるため。
    DispatchQueue.main.async { runner?.stopAll() }
    onEnd()
  }
}
