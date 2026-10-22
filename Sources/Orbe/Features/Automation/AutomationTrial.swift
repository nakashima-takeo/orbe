import Foundation

/// 試走——自動化の部品を、本番を汚さずに本番と同じ流しで動かし、部品の回ごとの結果を集める 1 回。main で使う。
///
/// 本番の DB を区切ってメモリの DB へ写し（`AutomationStore.Copy`）、写しの上に本番と同じ走らせ役を立てて、範囲の道だけを番人に
/// 載せて流す。読む・確定・出す側の行・起こす決まり・出し直しは本番のコードのまま写しの上で動き、本番の DB には届かない。
/// 本番と変えるのは部品の 1 回の起こし方と、道の根から出るつながりの受け手の読みだけ: 副作用と仕事は手段を起こさず、取った行を
/// 止めた行として成功の回で終える（失敗にすると読んだ位置が進まず、上流の契機のたびのやり直しで同じ行が起こされ続ける）。行を
/// 与えた取得の入口は手段を起こさず、与えた項目をその回の出力として書く（出来事の見分けは掛けない）。入力のある入口に与えた行は、
/// その上流の出力として写しに足す。根の受け手は、与えた行を読んだ位置によらず読み、その回が有効にした行と与えた行を先頭から
/// `limit` 行に絞る。
///
/// 写しの上では試走する自動化を止めた状態にする——予定の時刻と、登録時の起こしを持たせないため。ほかの自動化は写しに残るが
/// 番人に載せないので動かず、候補の帳面だけが判定の「既に候補がある」に効く。流しが終わるか打ち切られたら写しを捨てる。
final class AutomationTrial {
  struct Request: Equatable {
    /// 入口の部品。省けば、行き先とその祖先のうち入力の無い部品すべて。
    var from: [String]?
    /// 行き先の部品。省けば、入口から届く終わりの部品すべて。
    var to: [String]?
    /// 入口に与える行（1 行 1 JSON オブジェクト）。道の根が 1 つのときだけ受ける。
    var rows: [String]?
    /// 取得が下流へ渡す行の上限。
    var limit: Int?
  }

  /// 解いた範囲。
  struct Range {
    let from: [AutomationPartID]
    let to: [AutomationPartID]
    /// 道——入口のどれかの子孫か入口そのもので、行き先のどれかの祖先か行き先そのものの部品（定義の順）。
    let path: [AutomationGraph.Node]

    /// 道の根（道の上の入力を持たない部品）。
    var roots: [AutomationGraph.Node] {
      let ids = Set(path.map(\.id))
      return path.filter { ids.isDisjoint(with: $0.inputParts) }
    }
  }

  /// 与えた行の入れ方。
  enum Given {
    /// 取得の入口が取った項目として読んだもの（読めた項目の数を添える）。
    case fetched(part: AutomationPartID, output: AutomationPartPass.Output, count: Int)
    /// 入力のある入口の、ただ 1 つの上流の出力として足す行。
    case arrivals(part: AutomationPartID, upstream: AutomationPartID, rows: [AutomationPartRow])
  }

  enum PartState: String {
    case waiting
    case running
    case done
    /// 副作用・仕事の部品を止めて終えた。
    case held
    /// 打ち切りで動かなかった。
    case untouched
  }

  /// 部品の 1 回の結果。記録は写しの上で確定した回の記録（本番の `runs` の要素と同じ形）。
  struct Pass {
    let run: AutomationPartRun
    let content: Content
  }

  enum Content: Equatable {
    case none
    /// 下流へ渡す行（取得・処理）。
    case rows([String])
    /// 候補の案と、対応済みにするリンク（判定）。
    case judged(proposals: [AutomationPartPass.Proposal], resolved: [String])
    /// 渡るはずだった行（止めた副作用・仕事）。
    case held([String])
  }

  let automationId: Int
  let request: Request
  let startedAt: Date
  /// 始めたときの定義で解き、写し終えた時点の定義で解き直す。
  private(set) var range: Range
  private(set) var endedAt: Date?
  /// 流す前に終わった理由（写している間に範囲の部品が消えた など）。
  private(set) var failure: String?
  /// 部品ごとの回（本番の `runs` と同じく新しい順）。
  private(set) var passes: [AutomationPartID: [Pass]] = [:]

  private let source: AutomationRunner
  private let onEnd: () -> Void
  private var copy: AutomationStore.Copy?
  private var runner: AutomationRunner?
  private var given: Given?
  /// 終わったときの一巡（打ち切られたものを含む）。
  private var finalFlow: AutomationFlow?
  /// 部品ごとの、走っている回で止めた行。
  private var held: [AutomationPartID: [String]] = [:]
  /// 受け手ごとの、根から出るつながりの読みの上書き。
  private var overrides: [AutomationPartID: [AutomationReadOverride]] = [:]
  private var stopped = false

  /// `source` は本番の走らせ役（ストア・実行の係・時計・workspace を借りる）。`onEnd` は終わったときに 1 度だけ呼ぶ。
  init(
    automationId: Int, request: Request, range: Range, source: AutomationRunner,
    onEnd: @escaping () -> Void
  ) {
    self.automationId = automationId
    self.request = request
    self.range = range
    self.source = source
    self.onEnd = onEnd
    startedAt = source.now()
  }

  var running: Bool { endedAt == nil }

  /// 写している途中か。
  var preparing: Bool { copy != nil }

  func state(of key: AutomationPartID) -> PartState {
    let done: PartState =
      switch range.path.first(where: { $0.id == key })?.role {
      case .sideEffect, .work: .held
      default: .done
      }
    guard running else { return finalFlow?.isDone(key) == true ? done : .untouched }
    if runner?.currentFlow(automationId)?.isDone(key) == true { return done }
    return runner?.isRunning(automationId, key) == true ? .running : .waiting
  }

  // MARK: - 流れ

  /// 写し始める。写しは画面の合間に 1 区切りずつ進める。
  func begin() throws(AutomationError) {
    copy = try source.store.copy()
    stepLater()
  }

  /// 止める。写しも走っている手段も止め、以後は何も集めない。
  func stop() {
    guard !stopped else { return }
    stopped = true
    copy = nil
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

  /// 写し終えた時点の定義で範囲を解き直し、写しの上で流す。
  private func flow(on store: AutomationStore) throws(AutomationError) {
    let id = automationId
    guard let automation = store.automation(id) else { throw .automationNotFound(id) }
    range = try Self.range(of: automation, request)
    if let rows = request.rows { given = try Self.given(rows, in: range, of: automation.graph) }
    if !automation.paused { _ = try store.setPaused(id, true, now: source.now()) }
    if case .arrivals(let part, let upstream, let rows) = given {
      let refs = try store.give(rows, as: upstream, of: id, at: source.now())
      overrides[part] = [
        AutomationReadOverride(edge: upstream, given: refs, fresh: [], limit: request.limit)
      ]
    }
    let path = Set(range.path.map(\.id))
    let runner = AutomationRunner(
      store: store, run: source.run, workspaces: source.workspaces,
      recorded: { [weak self] in self?.recorded($0) }, defined: { _ in }, deleted: { _ in },
      startPass: { [weak self] start, completion in
        self?.startPass(start, completion) ?? BackgroundRunHandle {}
      },
      admits: { $0 == id && path.contains($1) },
      flowEnded: { [weak self] _, flow in self?.flowEnded(flow) })
    runner.now = source.now
    runner.calendar = source.calendar
    runner.overrides = { [weak self] _, part in self?.overrides[part] ?? [] }
    self.runner = runner
    runner.start()
    try runner.flow(id, through: path, to: range.to)
  }

  private func startPass(
    _ start: AutomationPassStart,
    _ completion: @escaping (AutomationPartPass.Outcome) -> Void
  ) -> BackgroundRunHandle {
    let node = start.node
    switch node.role {
    case .sideEffect, .work:
      // 仕事の行は役割の入力に載らないので、読んだものから引く。
      let rows = start.read?.taken.map(\.text) ?? []
      held[node.id] = rows
      let output: AutomationPartPass.Output =
        node.role == .sideEffect ? .sideEffect : .work(.nothing(AutomationEnding.heldByTrial.text))
      return later(
        .succeeded(
          output,
          AutomationPartPass.Execution(
            commandLine: "", ending: .heldByTrial, count: rows.count), breach: nil),
        completion)
    case .fetch:
      if case .fetched(let part, let output, let count) = given, part == node.id {
        return later(
          .succeeded(
            output,
            AutomationPartPass.Execution(commandLine: "", ending: .givenToTrial, count: count),
            breach: nil),
          completion)
      }
      return start.pass.start(node, start.input, completion: completion)
    case .process, .judge, .report:
      return start.pass.start(node, start.input, completion: completion)
    }
  }

  /// 手段を起こさない回も、結果は普段の部品の 1 回と同じく後の main で返す（起こした契機の中へ同期に戻さない）。
  private func later(
    _ outcome: AutomationPartPass.Outcome,
    _ completion: @escaping (AutomationPartPass.Outcome) -> Void
  ) -> BackgroundRunHandle {
    let item = DispatchWorkItem { completion(outcome) }
    DispatchQueue.main.async(execute: item)
    return BackgroundRunHandle { item.cancel() }
  }

  private func recorded(_ record: AutomationPassRecord) {
    let key = record.end.part
    guard !stopped, let run = record.run, let node = range.path.first(where: { $0.id == key })
    else { return }
    if range.roots.contains(where: { $0.id == key }), !run.failed, node.role.isFetch,
      record.end.given || request.limit != nil
    {
      let given = record.end.given ? Set(record.recorded.outputs.map(\.ref)) : []
      let fresh = Set(record.recorded.outputs.filter(\.fresh).map(\.ref))
      for receiver in range.path where receiver.inputParts.contains(key) {
        overrides[receiver.id] = [
          AutomationReadOverride(edge: key, given: given, fresh: fresh, limit: request.limit)
        ]
      }
    }
    let content: Content
    switch node.role {
    case .sideEffect, .work:
      content = .held(held.removeValue(forKey: key) ?? [])
    case .fetch, .process:
      let flowing = record.recorded.outputs.filter { $0.fresh || record.end.given }.map(\.text)
      let root = range.roots.contains { $0.id == key }
      content =
        run.failed
        ? .none
        : .rows(root ? Array(flowing.prefix(request.limit ?? flowing.count)) : flowing)
    case .judge:
      if !run.failed,
        case .succeeded(.judge(let proposals, let resolved), _, _) = record.end.outcome
      {
        content = .judged(proposals: proposals, resolved: resolved)
      } else {
        content = .none
      }
    case .report:
      content = .none
    }
    passes[key, default: []].insert(Pass(run: run, content: content), at: 0)
  }

  private func flowEnded(_ flow: AutomationFlow) {
    guard !stopped, running else { return }
    finalFlow = flow
    end(failure: nil)
  }

  private func end(failure: String?) {
    self.failure = failure
    endedAt = source.now()
    let runner = self.runner
    self.runner = nil
    // 走らせ役の知らせの中から呼ばれうるので、番人から外すのは知らせを返した後にする。外すのは、終わった後に起き直した部品の
    // 手段を止めるため。
    DispatchQueue.main.async { runner?.stopAll() }
    onEnd()
  }

  private static func reason(_ error: AutomationError) -> String {
    switch error {
    case .invalid(let message), .unavailable(let message): message
    case .automationNotFound(let id): "automation not found: \(id)"
    case .partNotFound(let id, let key): "part not found: \(key) in automation \(id)"
    case .unreadable(let id, let reason): "automation \(id) cannot be read: \(reason)"
    case .proposalNotFound, .proposalNotOpen, .flowing, .trialNotFound, .versionMismatch:
      "\(error)"
    }
  }
}
