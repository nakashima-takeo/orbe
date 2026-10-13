import Foundation
import OrbeSessionLog

/// 自動化を番人に載せ、1 回（取得元 → 枠の差分 → 出力先の取り込み → 段を 1 つずつ → 出力先が読む・届ける → 確定）を
/// まるごと番人の 1 回として進める。main で使う。
///
/// 1 回が終わるまで同じ自動化の次の回は始まらない（重ねない保証・「今すぐ」・走っているかは番人が持つ）。番人が回を止めたら
/// （何をするかの書き換え・削除）、走っている段か届けを止め、以後の確定を行わない。定義の変異はここを通し、番人の登録を
/// 合わせる。状態を読み書きするのは枠（ストア）と出力先だけで、段は状態を持たない。回を記録するたびに `recorded` で
/// 自動化の ID を知らせる（知らせるかどうか・何を出すかは受けた側がストアの今の値から決める）。消したら `deleted` で知らせる。
final class AutomationRunner {
  let store: AutomationStore
  var now: () -> Date = Date.init
  var calendar: () -> Calendar = { Calendar.current }

  private let scheduler: BackgroundScheduler
  private let run: BackgroundScheduler.Run
  private let recorded: (Int) -> Void
  private let deleted: (Int) -> Void

  init(
    store: AutomationStore, scheduler: BackgroundScheduler = BackgroundScheduler(),
    run: @escaping BackgroundScheduler.Run = { BackgroundRuns.shared.run($0, completion: $1) },
    recorded: @escaping (Int) -> Void, deleted: @escaping (Int) -> Void
  ) {
    self.store = store
    self.scheduler = scheduler
    self.run = run
    self.recorded = recorded
    self.deleted = deleted
  }

  /// 起動時に一度、全自動化を番人へ載せる（止めた自動化は予定なしで）。
  func start() {
    for automation in store.automations { register(automation) }
  }

  // MARK: - 定義の変異

  /// `id` が nil なら作り、あれば丸ごと置き換える。何をするかが変われば走っている回を止めて載せ直し、名前・トリガー・
  /// 取得の性質・段の名前だけなら予定だけを差し替える（走っている回は最後まで走る）。
  func set(_ id: Int?, _ definition: AutomationDefinition) throws(AutomationError) -> Automation {
    guard let id else {
      let automation = try store.create(definition, now: now())
      register(automation)
      return automation
    }
    let (automation, reworked) = try store.replace(id, with: definition)
    if reworked { register(automation) } else { retime(automation) }
    return automation
  }

  /// 止めるのは予定だけ。走っている回は止めない。
  func pause(_ id: Int, _ paused: Bool) throws(AutomationError) -> Automation {
    let automation = try store.setPaused(id, paused)
    retime(automation)
    return automation
  }

  /// 消す。走っている回は止め、その結果は捨てる。
  func delete(_ id: Int) throws(AutomationError) {
    try store.delete(id)
    scheduler.remove(id: Self.key(id))
    deleted(id)
  }

  /// 今すぐ回す（止めた自動化も受ける）。走っている回があれば断る。
  func runNow(_ id: Int) throws(AutomationError) {
    guard store.automation(id) != nil else { throw .automationNotFound(id) }
    guard !isRunning(id) else { throw .running(id) }
    scheduler.runNow(id: Self.key(id))
  }

  func isRunning(_ id: Int) -> Bool {
    scheduler.isRunning(id: Self.key(id))
  }

  /// `now`（渡さなければ走らせ役の今）から見て次に予定で回る時刻（止めていれば nil）。過ぎていれば `now` 以前の時刻を返す。
  func nextRunAt(_ automation: Automation, now: Date? = nil) -> Date? {
    guard !automation.paused else { return nil }
    switch automation.definition.trigger.next(
      after: automation.anchor, deadline: nil, now: now ?? self.now(), calendar: calendar())
    {
    case .run(let date): return date
    case .expire: return nil
    }
  }

  // MARK: - 番人

  private static func key(_ id: Int) -> String { "automation:\(id)" }

  private func timing(_ automation: Automation) -> BackgroundTiming? {
    automation.paused ? nil : automation.definition.trigger
  }

  /// ストアの定義は検証済みなので、番人の検証で落ちることはない。
  private func register(_ automation: Automation) {
    let id = automation.id
    let start: BackgroundScheduler.Start = { [weak self] trigger, finish in
      self?.begin(id, trigger: trigger, finish: finish) ?? BackgroundRunHandle {}
    }
    try? scheduler.register(
      id: Self.key(id), timing: timing(automation), anchor: automation.anchor, start: start)
  }

  private func retime(_ automation: Automation) {
    try? scheduler.retime(id: Self.key(automation.id), timing: timing(automation))
  }

  // MARK: - 1 回

  private func begin(
    _ id: Int, trigger: BackgroundScheduler.Trigger, finish: @escaping (Date) -> Void
  ) -> BackgroundRunHandle {
    // 番人の上に「走っている」を残さないよう、自動化が無ければ回はすぐ終わったものとして知らせる。
    guard let automation = store.automation(id) else {
      finish(now())
      return BackgroundRunHandle {}
    }
    let definition = automation.definition
    let attempt = Attempt(
      automationId: id, definition: definition, trigger: trigger == .now ? .now : .schedule,
      startedAt: now(), finish: finish)
    switch definition.sink {
    case .taskCandidates:
      runSource(Pass(attempt, AutomationTaskCandidates(store: store, automationId: id)), automation)
    case .command(let command):
      let sink = AutomationCommandSinkRun(
        command, runId: automation.runId, gate: AutomationRowGate(definition), run: run)
      runSource(Pass(attempt, sink), automation)
    case .report:
      runSource(Pass(attempt, AutomationReportSinkRun()), automation)
    case .agent(let agent):
      let sink = AutomationAgentSinkRun(
        agent, gate: AutomationRowGate(definition), run: run, now: now, calendar: calendar)
      runSource(Pass(attempt, sink), automation)
    }
    return BackgroundRunHandle {
      attempt.cancelled = true
      attempt.current?.stop()
    }
  }

  /// 新着の流れの取得元にだけ、前回成功した回の開始時刻を目印として渡す。
  private func runSource<Sink>(_ pass: Pass<Sink>, _ automation: Automation) {
    guard let source = automation.definition.source else {
      forward([], pass)
      return
    }
    let since = source.coverage == .newArrivals ? automation.lastSucceededAt : nil
    launch(Self.sourceJob(source, since: since), pass) { [weak self] result in
      self?.sourced(result, pass)
    }
  }

  private func sourced<Sink>(_ result: BackgroundRunResult, _ pass: Pass<Sink>) {
    var report = AutomationStepReport(
      name: nil, commandLine: result.commandLine, ending: result.ending.text, count: 0,
      rejected: AutomationRejections())
    let fetched: [AutomationItem]
    switch Self.readSource(result) {
    case .failed(let reason, let rejected):
      report.rejected = rejected
      pass.record.source = report
      fail(pass, reason)
      return
    case .items(let items, let rejected):
      report.count = items.count
      report.rejected = rejected
      fetched = items
    }
    pass.record.source = report
    pass.fetched = fetched
    let fresh = pass.sink.admit(
      store.unseen(of: pass.attempt.automationId, in: fetched), fetched: fetched)
    pass.record.fresh = fresh.count
    guard !fresh.isEmpty else {
      settle(pass, nil)
      return
    }
    forward(fresh.map(AutomationPrompts.row), pass)
  }

  /// 決まった行を、段があれば最初の段へ、無ければ出力先へ渡す。
  private func forward<Sink>(_ rows: [String], _ pass: Pass<Sink>) {
    guard pass.attempt.definition.steps.isEmpty else {
      runStep(0, rows: rows, pass)
      return
    }
    guard let rows = prepared(rows, pass) else { return }
    toSink(rows.map { $0 + "\n" }.joined(), step: nil, pass)
  }

  /// 出力先へ向かう最後の入力を出力先に確かめさせる。行があったのに全部外れたら回を失敗にして nil を返す。
  private func prepared<Sink>(_ rows: [String], _ pass: Pass<Sink>) -> [String]? {
    let checked = pass.sink.prepare(rows)
    guard checked.count > 0 || rows.isEmpty else {
      fail(pass, "no line passed to the last step has the id of a new item")
      return nil
    }
    return checked
  }

  private func runStep<Sink>(_ index: Int, rows: [String], _ pass: Pass<Sink>) {
    let definition = pass.attempt.definition
    let last = index == definition.steps.count - 1
    var rows = rows
    if last {
      guard let checked = prepared(rows, pass) else { return }
      rows = checked
    }
    let job: BackgroundJob
    switch definition.steps[index].method {
    case .command(let command):
      job = .command(
        command, input: BackgroundInput(stdin: Data(rows.map { $0 + "\n" }.joined().utf8)))
    case .agent(let agent):
      let instruction = agent.instruction
      let prompt =
        last
        ? pass.sink.prompt(
          instruction: instruction, rows: rows, now: now(), timeZone: calendar().timeZone)
        : AutomationPrompts.step(
          instruction: instruction, rows: rows, now: now(), timeZone: calendar().timeZone)
      job = .agent(
        BackgroundAgentCall(
          cli: agent.cli, model: definition.model(of: agent, at: index), tools: [],
          prompt: prompt))
    }
    launch(job, pass) { [weak self] result in
      self?.stepped(result, index, pass)
    }
  }

  private func stepped<Sink>(_ result: BackgroundRunResult, _ index: Int, _ pass: Pass<Sink>) {
    let definition = pass.attempt.definition
    let name = definition.steps[index].name
    var report = AutomationStepReport(
      name: name, commandLine: result.commandLine, ending: result.ending.text, count: 0,
      rejected: AutomationRejections())
    let text: String
    switch AutomationRunOutput.text(result, role: "step \"\(name)\"") {
    case .failure(let failure):
      pass.record.steps.append(report)
      fail(pass, failure.reason)
      return
    case .success(let output):
      text = output
    }
    guard index < definition.steps.count - 1 else {
      toSink(text, step: report, pass)
      return
    }
    let reading = AutomationPrompts.readStep(text, step: "step \"\(name)\"")
    report.count = reading.rows.count
    report.rejected = reading.rejected
    pass.record.steps.append(report)
    if let failure = reading.failure {
      fail(pass, failure)
    } else if reading.rows.isEmpty {
      settle(pass, nil)
    } else {
      runStep(index + 1, rows: reading.rows.map(\.text), pass)
    }
  }

  /// 出力先に読ませて届ける。`text` は最後の段の出力（段が無ければ出力先が読む行）。最後の段の記録 `step` には、出力先が
  /// 数えた数を載せて回の記録に足す。出力先で落ちた回は、出力先の記録も回の記録に残す。
  private func toSink<Sink>(_ text: String, step: AutomationStepReport?, _ pass: Pass<Sink>) {
    var step = step
    let output: Sink.Output
    switch pass.sink.read(text) {
    case .failed(let reason, let rejected):
      step?.rejected = rejected
      if let step { pass.record.steps.append(step) }
      fail(pass, reason)
      return
    case .output(let read, let count, let rejected):
      step?.count = count
      step?.rejected = rejected
      if let step {
        pass.record.steps.append(step)
        pass.record.lastStepCountedBySink = true
      }
      output = read
    }
    pass.attempt.current = pass.sink.deliver(output) { [weak self] failure in
      guard !pass.attempt.cancelled else { return }
      if let failure {
        pass.record.sink = failure.report
        self?.fail(pass, failure.reason)
      } else {
        self?.settle(pass, output)
      }
    }
  }

  /// 走らせ、止められていなければ結果を渡す。
  private func launch<Sink>(
    _ job: BackgroundJob, _ pass: Pass<Sink>, then: @escaping (BackgroundRunResult) -> Void
  ) {
    pass.attempt.current = run(job) { result in
      guard !pass.attempt.cancelled else { return }
      then(result)
    }
  }

  /// 確定（成功）。
  private func settle<Sink>(_ pass: Pass<Sink>, _ output: Sink.Output?) {
    let sink = pass.sink
    let endedAt = now()
    pass.record.endedAt = endedAt
    store.commit(pass.attempt.automationId, pass.record, fetched: pass.fetched) {
      sink.commit(output, into: &$0, automations: $1, endedAt: endedAt)
    }
    recorded(pass.attempt.automationId)
    pass.attempt.finish(pass.record.startedAt)
  }

  /// 失敗した回。記録と最後に回った時刻だけを進める。
  private func fail<Sink>(_ pass: Pass<Sink>, _ reason: String) {
    pass.record.endedAt = now()
    pass.record.failure = reason
    store.recordFailure(of: pass.attempt.automationId, pass.record)
    recorded(pass.attempt.automationId)
    pass.attempt.finish(pass.record.startedAt)
  }
}

/// 1 回の流れで運ぶもの。
extension AutomationRunner {
  /// 走っている 1 回。止められたら、以後の結果は捨てる。
  private final class Attempt {
    let automationId: Int
    let definition: AutomationDefinition
    let trigger: AutomationRun.Trigger
    /// Orbe が回を始めた時刻。
    let startedAt: Date
    let finish: (Date) -> Void
    var current: BackgroundRunHandle?
    var cancelled = false

    init(
      automationId: Int, definition: AutomationDefinition, trigger: AutomationRun.Trigger,
      startedAt: Date, finish: @escaping (Date) -> Void
    ) {
      self.automationId = automationId
      self.definition = definition
      self.trigger = trigger
      self.startedAt = startedAt
      self.finish = finish
    }
  }

  /// 1 回の流れで持ち越すもの。出力先の型を型引数に持つので、読んだ出力を型を消さずに確定まで運ぶ。
  private final class Pass<Sink: AutomationSinkRun> {
    let attempt: Attempt
    let sink: Sink
    var record: AutomationRun
    var fetched: [AutomationItem] = []

    /// 終わりは確定か失敗のときに入る。
    init(_ attempt: Attempt, _ sink: Sink) {
      self.attempt = attempt
      self.sink = sink
      record = AutomationRun(
        startedAt: attempt.startedAt, endedAt: attempt.startedAt, trigger: attempt.trigger,
        source: nil, fresh: nil, steps: [], lastStepCountedBySink: false, sink: nil, failure: nil)
    }
  }
}

/// 走らせるものの組み立てと、取得の出力の読み取り。
extension AutomationRunner {
  fileprivate static func sourceJob(_ source: AutomationSource, since: Date?) -> BackgroundJob {
    switch source.method {
    case .command(let command):
      var input = BackgroundInput()
      if let since { input.environment["ORBE_SINCE"] = SessionEvent.iso8601(since) }
      return .command(command, input: input)
    case .agent(let agent):
      return .agent(
        BackgroundAgentCall(
          cli: agent.cli, model: AutomationDefinition.model(agent.model, finalStep: false),
          tools: agent.tools, prompt: AutomationPrompts.fetch(request: agent.request, since: since))
      )
    }
  }

  fileprivate static func readSource(_ result: BackgroundRunResult)
    -> AutomationPrompts.FetchReading
  {
    switch AutomationRunOutput.text(result, role: "fetch") {
    case .failure(let failure): .failed(failure.reason, rejected: AutomationRejections())
    case .success(let text): AutomationPrompts.readFetch(text)
    }
  }
}
