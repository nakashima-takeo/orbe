import Foundation

/// 試走——自動化のノードを、本番を汚さずに本番と同じ流しで動かし、ノードの回ごとの結果を集める 1 回。main で使う。
///
/// 本番の DB を区切ってメモリの DB へ写し（`AutomationStore.Copy`）、写しの上に本番と同じ走らせ役を立てて、範囲の道だけを番人に
/// 載せて流す。読む・確定・出す側の行・起こす決まり・結果の確かめは本番のコードのまま写しの上で動き、本番の DB には届かない。
/// 本番の層は試走を知らない。試走の都合は、試走が自分の写しに掛ける操作（`AutomationTrial+Copy`）と、載せるノードの選び方だけで
/// 表す:
///
/// - 副作用と仕事は止めるノードで、写しの上でも動かさない（載せない）。流しの終わりに、本番の読みで取るはずだった行を 1 回だけ
///   読んで返す。
/// - 与えた行は、取得の入口ならその取得の、入力のある入口ならただ 1 つの上流の出力として、写しに新しい行で書く。取得の入口は
///   動かない（載せない）。
/// - `limit` は、道の根の取得の回が写しに確定した直後、受け手が読む前に、その回が足した新しい行のうち N 行を超えた分を写しから
///   取り除いて掛ける（与えた行は書く前に N 行に切る）。
///
/// 写しの上では試走する自動化を止めた状態にする——予定の時刻と、登録時の起こしを持たせないため。ほかの自動化は写しに残るが
/// 番人に載せないので動かず、候補の帳面だけが判定の「既に候補がある」に効く。流しが終わるか打ち切られたら写しを捨てる。
final class AutomationTrial {
  struct Request: Equatable {
    /// 入口のノード。省けば、行き先とその祖先のうち入力の無いノードすべて。
    var from: [String]?
    /// 行き先のノード。省けば、入口から届く終わりのノードすべて。
    var to: [String]?
    /// 入口に与える行（1 行 1 JSON オブジェクト）。道の根が 1 つのときだけ受ける。
    var rows: [String]?
    /// 道の根の取得の回が新しく足す行の上限。毎回すべてを取る受け手は、前から今有効な行もあわせて読む。
    var limit: Int?
  }

  /// 解いた範囲。
  struct Range {
    let from: [AutomationNodeID]
    let to: [AutomationNodeID]
    /// 道——入口のどれかの子孫か入口そのもので、行き先のどれかの祖先か行き先そのもののノード（定義の順）。
    let path: [AutomationGraph.Node]

    /// 道の根（道の上の入力を持たないノード）。
    var roots: [AutomationGraph.Node] {
      let ids = Set(path.map(\.id))
      return path.filter { ids.isDisjoint(with: $0.inputNodeIds) }
    }
  }

  /// 与えた行: 書くノード（取得の入口ならその取得、入力のある入口ならただ 1 つの上流）と、その出力にする行。
  struct Given {
    let entry: AutomationNodeID
    let writer: AutomationNodeID
    let rows: [AutomationNodeRow]

    /// 取得の入口に与えたか（その取得は動かない）。
    var fetched: Bool { writer == entry }
  }

  enum NodeState: String {
    case waiting
    case running
    case done
    /// 副作用・仕事のノードを止めて終えた。
    case held
    /// 与えた行を出力にした取得（手段を起こさない）。
    case given
    /// 打ち切りで動かなかった。
    case untouched
  }

  /// ノードの結果。
  enum Pass: Equatable {
    /// 写しの上で確定した回（本番の `runs` の要素と同じ形）と、その中身。
    case ran(AutomationNodeRun, Content)
    /// 止めた副作用・仕事に渡るはずだった行。
    case held([String])
    /// 与えた行を出力にした取得が下流へ渡す行。
    case given([String])
  }

  enum Content: Equatable {
    case none
    /// 下流へ渡す行（取得・処理）。
    case rows([String])
    /// 候補の案と、対応済みにするリンク（判定）。
    case judged(proposals: [AutomationNodePass.Proposal], resolved: [String])
  }

  let automationId: Int
  let request: Request
  let startedAt: Date
  /// 始めたときの定義で解き、写し終えた時点の定義で解き直す。
  private(set) var range: Range
  private(set) var endedAt: Date?
  /// 流し切れずに終わった理由（写している間に範囲のノードが消えた・写しに掛ける操作が書けなかった など）。
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
  /// 流し切って終えたか（止めるノードを読んだか）。
  private var completed = false
  private var stopped = false

  /// `production` は本番の走らせ役（ストア・実行の係・時計・workspace を借りる）。`onEnd` は終わったときに 1 度だけ呼ぶ。
  init(
    automationId: Int, request: Request, range: Range, production: AutomationRunner,
    onEnd: @escaping () -> Void
  ) {
    self.automationId = automationId
    self.request = request
    self.range = range
    self.production = production
    self.onEnd = onEnd
    startedAt = production.now()
  }

  var running: Bool { endedAt == nil }

  /// 写している途中か。
  var preparing: Bool { copy != nil }

  func state(of nodeId: AutomationNodeID) -> NodeState {
    if nodeId == givenFetch { return .given }
    if let node = range.path.first(where: { $0.id == nodeId }), Self.holds(node) {
      if running { return .waiting }
      return completed ? .held : .untouched
    }
    guard running else { return finalFlow?.isDone(nodeId) == true ? .done : .untouched }
    if runner?.currentFlow(automationId)?.isDone(nodeId) == true { return .done }
    return runner?.isRunning(automationId, nodeId) == true ? .running : .waiting
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
      end(failure: Self.reason(error))
    }
  }

  /// 写し終えた時点の定義で範囲を解き直し、行を与え、止めるノードと行を与えた取得の入口を除いた道を写しの上で流す。行き先は、範囲
  /// の行き先のうち載せるノードと、止めるノードの上流で載せるノード。載せるノードが無ければ流さずに終える。
  private func flow(on store: AutomationStore) throws(AutomationError) {
    let id = automationId
    guard let automation = store.automation(id) else { throw .automationNotFound(id) }
    range = try Self.range(of: automation, request)
    var given: Given?
    if let rows = request.rows { given = try Self.given(rows, in: range, of: automation.graph) }
    if !automation.paused { _ = try store.setPaused(id, true, now: production.now()) }
    self.store = store
    if let given {
      let rows = request.limit.map { Array(given.rows.prefix($0)) } ?? given.rows
      try store.give(rows, as: given.writer, of: id, at: production.now())
      if given.fetched {
        givenFetch = given.entry
        passes[given.entry] = [
          .given(try store.latestRows(of: given.entry, in: id, count: rows.count))
        ]
      }
    }
    let held = range.path.filter(Self.holds)
    let admitted = Set(range.path.map(\.id)).subtracting(held.map(\.id))
      .subtracting([givenFetch].compactMap { $0 })
    let targets = range.path.map(\.id).filter { nodeId in
      admitted.contains(nodeId)
        && (range.to.contains(nodeId) || held.contains { $0.inputNodeIds.contains(nodeId) })
    }
    guard !targets.isEmpty else { return finish(completed: true) }
    let runner = AutomationRunner(
      store: store, run: production.run, runSessions: production.runSessions,
      workspaces: production.workspaces,
      recorded: { [weak self] in self?.recorded($0) }, defined: { _ in }, deleted: { _ in },
      admits: { $0 == id && admitted.contains($1) },
      flowEnded: { [weak self] _, flow in self?.flowEnded(flow) })
    runner.now = production.now
    runner.calendar = production.calendar
    self.runner = runner
    runner.start()
    try runner.flow(id, through: admitted, to: targets)
  }

  /// ノードの回の知らせ（確定の直後、下流が読む前）。取得・処理はその回が写しに足した新しい行を結果にし、道の根の取得なら先に
  /// `limit` で写しを絞る。判定は案を結果にする。
  private func recorded(_ record: AutomationPassRecord) {
    let nodeId = record.end.nodeId
    guard !stopped, let store, let run = record.run,
      let node = range.path.first(where: { $0.id == nodeId })
    else { return }
    let content: Content
    do throws(AutomationError) {
      content = try self.content(of: node, run, record.end.outcome, in: store)
    } catch {
      return end(failure: Self.reason(error))
    }
    passes[nodeId, default: []].insert(.ran(run, content), at: 0)
  }

  private func content(
    of node: AutomationGraph.Node, _ run: AutomationNodeRun,
    _ outcome: AutomationNodePass.Outcome, in store: AutomationStore
  ) throws(AutomationError) -> Content {
    guard !run.failed else { return .none }
    switch run.result {
    case .fetch(let fresh, _), .process(let fresh, _):
      var count = fresh
      if node.role == .fetch, let limit = request.limit, count > limit,
        range.roots.contains(where: { $0.id == node.id })
      {
        try store.trim(
          node.id, in: automationId, fresh: fresh, keeping: limit, now: production.now())
        count = limit
      }
      return .rows(try store.latestRows(of: node.id, in: automationId, count: count))
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

  /// 流しの終わり。流し切ったら、止めるノードごとに本番の読み（位置は進めない）で取るはずだった行を読み、あれば結果にする。
  private func finish(completed: Bool) {
    if completed, let store {
      do throws(AutomationError) {
        for node in range.path where Self.holds(node) {
          guard
            let read = try store.read(
              node.id, of: automationId, baseline: nil, now: production.now()),
            !read.taken.isEmpty
          else { continue }
          passes[node.id] = [.held(read.taken.map(\.text))]
        }
      } catch {
        return end(failure: Self.reason(error))
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

  private static func reason(_ error: AutomationError) -> String {
    switch error {
    case .invalid(let message), .unavailable(let message): message
    case .automationNotFound(let id): "automation not found: \(id)"
    case .nodeNotFound(let id, let key): "node not found: \(key) in automation \(id)"
    case .unreadable(let id, let reason): "automation \(id) cannot be read: \(reason)"
    case .proposalNotFound, .proposalNotOpen, .flowing, .trialNotFound, .versionMismatch:
      "\(error)"
    }
  }
}
