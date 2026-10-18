import Foundation

/// 試走——自動化の部品を、本番を汚さずに本番と同じ流しで動かし、部品の回ごとの結果を集める 1 回。main で使う。
///
/// 本番の DB を区切ってメモリの DB へ写し（`AutomationStore.Copy`）、写しの上に本番と同じ走らせ役を立てて、範囲の道だけを番人に
/// 載せて流す。取る・取り切る・確定・積む・起こす決まり・出し直しは本番のコードのまま写しの上で動き、本番の DB には届かない。
/// 本番と変えるのは部品の 1 回の起こし方だけ: 副作用と仕事は手段を起こさず、取った行を止めた行として成功の回で終える（失敗に
/// すると行が溜まりに残り、上流の契機のたびのやり直しで同じ行が起こされ続ける）。行を与えた取得の入口は手段を起こさず、与えた
/// 項目を前回の出力との差分なしに読む（既に見た項目を与えても流れるように）。取得が下流へ渡す行は `limit` で先頭から絞る。
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
    let from: [String]
    let to: [String]
    /// 道——入口のどれかの子孫か入口そのもので、行き先のどれかの祖先か行き先そのものの部品（定義の順）。
    let path: [AutomationGraph.Node]

    /// 道の根（道の上の入力を持たない部品）。
    var roots: [AutomationGraph.Node] {
      let keys = Set(path.map(\.key))
      return path.filter { keys.isDisjoint(with: $0.part.inputs) }
    }
  }

  /// 与えた行の入れ方。
  enum Given {
    /// 取得の入口が取った項目として読んだもの（読めた項目の数を添える）。
    case fetched(part: String, output: AutomationPartPass.Output, count: Int)
    /// 入力のある入口の溜まりへ届く行。
    case arrivals(part: String, rows: [AutomationPartRow])
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
  private(set) var passes: [String: [Pass]] = [:]

  private let source: AutomationRunner
  private let onEnd: () -> Void
  private var copy: AutomationStore.Copy?
  private var runner: AutomationRunner?
  private var given: Given?
  /// 終わったときの一巡（打ち切られたものを含む）。
  private var finalFlow: AutomationFlow?
  /// 部品ごとの、走っている回で止めた行。
  private var held: [String: [String]] = [:]
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

  func state(of key: String) -> PartState {
    let done: PartState =
      switch range.path.first(where: { $0.key == key })?.role {
      case .sideEffect, .work: .held
      default: .done
      }
    guard running else { return finalFlow?.isDone(key) == true ? done : .untouched }
    if runner?.currentFlow(automationId)?.isDone(key) == true { return done }
    return runner?.isRunning(automationId, key) == true ? .running : .waiting
  }

  // MARK: - 範囲

  /// 範囲を解く。知らない部品は `partNotFound`、どの行き先にも届かない入口・どの入口からも届かない行き先は `invalid`。
  static func range(of automation: Automation, _ request: Request) throws(AutomationError) -> Range
  {
    let graph = automation.graph
    func checked(_ keys: [String]?, _ name: String) throws(AutomationError) -> [String]? {
      guard let keys else { return nil }
      guard !keys.isEmpty else { throw .invalid("\(name) must name at least one part") }
      for key in keys where graph.node(key) == nil { throw .partNotFound(automation.id, key) }
      return keys
    }
    func below(_ keys: [String]) -> Set<String> {
      Set(keys + keys.flatMap { graph.descendants(of: $0).map(\.key) })
    }
    func above(_ keys: [String]) -> Set<String> {
      Set(keys + keys.flatMap { graph.ancestors(of: $0).map(\.key) })
    }
    let from = try checked(request.from, "from")
    let to = try checked(request.to, "to")
    let targets =
      to ?? graph.ends.map(\.key).filter { from.map(below)?.contains($0) ?? true }
    let up = above(targets)
    let entries =
      from ?? graph.nodes.filter { $0.part.inputs.isEmpty && up.contains($0.key) }.map(\.key)
    let down = below(entries)
    for (index, key) in entries.enumerated() where !up.contains(key) {
      throw .invalid("from[\(index)] \"\(key)\" reaches no part in to")
    }
    for (index, key) in targets.enumerated() where !down.contains(key) {
      throw .invalid("to[\(index)] \"\(key)\" is not reached from any part in from")
    }
    return Range(
      from: unique(entries), to: unique(targets),
      path: graph.nodes.filter { up.contains($0.key) && down.contains($0.key) })
  }

  private static func unique(_ keys: [String]) -> [String] {
    var seen = Set<String>()
    return keys.filter { seen.insert($0).inserted }
  }

  /// 与えた行を、道の根（ちょうど 1 つ）の役割に合わせて読む。取得は取得の読み方で、入力のある部品は文字列の `id` を持つ行として
  /// 受ける。判定は断る——判定は出どころ（取得の項目）から候補を作るので、出どころの無い行は本番では捨てられる。
  static func given(_ rows: [String], in range: Range) throws(AutomationError) -> Given {
    let roots = range.roots
    guard roots.count == 1, let entry = roots.first else {
      throw .invalid(
        "rows need exactly one entry part (a part with no input in the range); this range has "
          + roots.map { "\"\($0.key)\"" }.joined(separator: ", "))
    }
    switch entry.role {
    case .judge:
      throw .invalid(
        "rows cannot be given to the judge part \"\(entry.key)\": a judge proposes only from items "
          + "a fetch part fetched, so give the items to a fetch part above it")
    case .fetch:
      switch AutomationPartPass.given(rows.joined(separator: "\n"), to: entry) {
      case .read(let output, let count, let lines) where lines.isEmpty:
        return .fetched(part: entry.key, output: output, count: count)
      case .read(_, _, let lines):
        throw .invalid("rows: \(lines[0].text)")
      case .failed(let reason):
        throw .invalid("rows: \(reason)")
      }
    case .process, .report, .work, .sideEffect:
      var arrivals: [AutomationPartRow] = []
      for (index, row) in rows.enumerated() {
        guard let id = AutomationPrompts.id(of: row) else {
          throw .invalid("rows: line \(index + 1): missing id")
        }
        arrivals.append(AutomationPartRow(id: id, text: row, origin: nil))
      }
      return .arrivals(part: entry.key, rows: arrivals)
    }
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
    if let rows = request.rows { given = try Self.given(rows, in: range) }
    if !automation.paused { _ = try store.setPaused(id, true) }
    if case .arrivals(let part, let rows) = given {
      try store.arrive(rows, into: part, of: id, at: source.now())
    }
    let path = Set(range.path.map(\.key))
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
      // 取った行は確定の前なのでまだ溜まりにある。仕事の行は役割の入力に載らないので、取った通し番号から読む。
      let rows = (try? runner?.store.rows(start.take?.taken ?? [])) ?? []
      held[node.key] = rows.map(\.text)
      let output: AutomationPartPass.Output =
        node.role == .sideEffect ? .sideEffect : .work(.nothing(Self.heldEnding))
      return later(
        .succeeded(
          output,
          AutomationPartPass.Execution(
            commandLine: "", ending: Self.heldEnding, count: rows.count), breach: nil),
        completion)
    case .fetch:
      if case .fetched(let part, let output, let count) = given, part == node.key {
        return later(
          limited(
            .succeeded(
              output,
              AutomationPartPass.Execution(
                commandLine: "", ending: Self.givenEnding, count: count), breach: nil)),
          completion)
      }
      return start.pass.start(node, start.input) { [weak self] outcome in
        completion(self?.limited(outcome) ?? outcome)
      }
    case .process, .judge, .report:
      return start.pass.start(node, start.input, completion: completion)
    }
  }

  private static let heldEnding = "held by the trial"
  private static let givenEnding = "rows given to the trial"

  /// 手段を起こさない回も、結果は普段の部品の 1 回と同じく後の main で返す（起こした契機の中へ同期に戻さない）。
  private func later(
    _ outcome: AutomationPartPass.Outcome,
    _ completion: @escaping (AutomationPartPass.Outcome) -> Void
  ) -> BackgroundRunHandle {
    let item = DispatchWorkItem { completion(outcome) }
    DispatchQueue.main.async(execute: item)
    return BackgroundRunHandle { item.cancel() }
  }

  private func limited(_ outcome: AutomationPartPass.Outcome) -> AutomationPartPass.Outcome {
    guard let limit = request.limit,
      case .succeeded(.fetch(let rows, let lastOutput), let execution, let breach) = outcome
    else { return outcome }
    return .succeeded(
      .fetch(rows: Array(rows.prefix(limit)), lastOutput: lastOutput), execution, breach: breach)
  }

  private func recorded(_ record: AutomationPassRecord) {
    let key = record.end.part
    guard !stopped, let run = record.run, let node = range.path.first(where: { $0.key == key })
    else { return }
    let content: Content
    switch node.role {
    case .sideEffect, .work:
      content = .held(held.removeValue(forKey: key) ?? [])
    case .fetch, .process, .judge, .report:
      content = run.failed ? .none : Self.content(of: record.end.outcome)
    }
    passes[key, default: []].append(Pass(run: run, content: content))
  }

  private static func content(of outcome: AutomationPartPass.Outcome) -> Content {
    guard case .succeeded(let output, _, _) = outcome else { return .none }
    switch output {
    case .fetch(let rows, _), .process(let rows): return .rows(rows.map(\.text))
    case .judge(let proposals, let resolved):
      return .judged(proposals: proposals, resolved: resolved)
    case .report, .work, .sideEffect: return .none
    }
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
    case .proposalNotFound, .proposalNotOpen, .flowing, .trialNotFound: "\(error)"
    }
  }
}
