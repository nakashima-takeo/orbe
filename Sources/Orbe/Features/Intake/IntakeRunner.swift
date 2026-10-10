import Foundation

/// 受信を番人に載せ、1 回（取得 → 新しい項目の抽出 → 判定 → 確定）をまるごと番人の 1 回として進める。main で使う。
///
/// 1 回が終わるまで同じ受信の次の回は始まらない（重ねない保証・「今すぐ」・走っているかは番人が持つ）。番人が回を止めたら
/// （取得か判定の書き換え・削除）、走っている段を止め、以後の確定を行わない。定義の変異はここを通し、番人の登録を合わせる。
final class IntakeRunner {
  let store: IntakeStore
  var now: () -> Date = Date.init
  var calendar: () -> Calendar = { Calendar.current }

  private let scheduler: BackgroundScheduler
  private let run: BackgroundScheduler.Run
  /// 「今すぐ」で始めている受信（番人は始め方を同期で呼ぶので、その間だけ立つ）。
  private var startingNow: Int?

  init(
    store: IntakeStore, scheduler: BackgroundScheduler = BackgroundScheduler(),
    run: @escaping BackgroundScheduler.Run = { BackgroundRuns.shared.run($0, completion: $1) }
  ) {
    self.store = store
    self.scheduler = scheduler
    self.run = run
  }

  /// 起動時に一度、全受信を番人へ載せる（止めた受信は予定なしで）。
  func start() {
    for intake in store.intakes { register(intake) }
  }

  // MARK: - 定義の変異

  /// `id` が nil なら作り、あれば丸ごと置き換える。取得か判定が変われば走っている回を止めて載せ直し、名前やいつだけなら
  /// 予定だけを差し替える（走っている回は最後まで走る）。
  func set(_ id: Int?, _ definition: IntakeDefinition) throws(IntakeError) -> Intake {
    guard let id else {
      let intake = try store.create(definition, now: now())
      register(intake)
      return intake
    }
    let (intake, reworked) = try store.replace(id, with: definition)
    if reworked { register(intake) } else { retime(intake) }
    return intake
  }

  /// 止めるのは予定だけ。走っている回は止めない。
  func pause(_ id: Int, _ paused: Bool) throws(IntakeError) -> Intake {
    let intake = try store.setPaused(id, paused)
    retime(intake)
    return intake
  }

  /// 消す。走っている回は止め、その結果は捨てる。
  func delete(_ id: Int) throws(IntakeError) {
    try store.delete(id)
    scheduler.remove(id: Self.key(id))
  }

  /// 今すぐ回す（止めた受信も受ける）。走っている回があれば断る。
  func runNow(_ id: Int) throws(IntakeError) {
    guard store.intake(id) != nil else { throw .intakeNotFound(id) }
    guard !isRunning(id) else { throw .running(id) }
    startingNow = id
    defer { startingNow = nil }
    scheduler.runNow(id: Self.key(id))
  }

  func isRunning(_ id: Int) -> Bool {
    scheduler.isRunning(id: Self.key(id))
  }

  /// 次に予定で回る時刻（止めていれば nil）。過ぎていれば今以前の時刻を返す。
  func nextRunAt(_ intake: Intake) -> Date? {
    guard !intake.paused else { return nil }
    switch intake.definition.when.next(
      after: intake.anchor, deadline: nil, now: now(), calendar: calendar())
    {
    case .run(let date): return date
    case .expire: return nil
    }
  }

  // MARK: - 番人

  private static func key(_ id: Int) -> String { "intake:\(id)" }

  private func timing(_ intake: Intake) -> BackgroundTiming? {
    intake.paused ? nil : intake.definition.when
  }

  /// ストアの定義は検証済みなので、番人の検証で落ちることはない。
  private func register(_ intake: Intake) {
    let id = intake.id
    let start: BackgroundScheduler.Start = { [weak self] finish in
      self?.begin(id, finish: finish) ?? BackgroundRunHandle {}
    }
    try? scheduler.register(
      id: Self.key(id), timing: timing(intake), anchor: intake.anchor, start: start)
  }

  private func retime(_ intake: Intake) {
    try? scheduler.retime(id: Self.key(intake.id), timing: timing(intake))
  }

  // MARK: - 1 回

  private func begin(_ id: Int, finish: @escaping (Date) -> Void) -> BackgroundRunHandle {
    // 番人の上に「走っている」を残さないよう、受信が無ければ回はすぐ終わったものとして知らせる。
    guard let intake = store.intake(id) else {
      finish(now())
      return BackgroundRunHandle {}
    }
    let attempt = Attempt(
      intakeId: id, definition: intake.definition,
      trigger: startingNow == id ? .now : .schedule, finish: finish)
    attempt.current = run(Self.fetchJob(intake.definition.fetch)) { [weak self] result in
      guard !attempt.cancelled else { return }
      self?.fetched(result, attempt)
    }
    return BackgroundRunHandle {
      attempt.cancelled = true
      attempt.current?.stop()
    }
  }

  private func fetched(_ result: BackgroundRunResult, _ attempt: Attempt) {
    let reading = Self.readFetch(result)
    var record = IntakeRun(
      startedAt: result.startedAt, endedAt: result.endedAt, trigger: attempt.trigger,
      fetch: IntakeFetchReport(
        commandLine: result.commandLine, ending: result.ending.text, items: 0,
        rejected: IntakeRejections()),
      newItems: 0, judge: nil, withdrawn: 0, failure: nil)
    let items: [IntakeItem]
    switch reading {
    case .failed(let reason, let rejected):
      record.fetch.rejected = rejected
      record.failure = reason
      store.recordFailure(of: attempt.intakeId, record)
      attempt.finish(result.startedAt)
      return
    case .items(let read, let rejected):
      record.fetch.items = read.count
      record.fetch.rejected = rejected
      items = read
    }
    let fresh = store.newItems(of: attempt.intakeId, in: items)
    record.newItems = fresh.count
    guard !fresh.isEmpty else {
      store.commit(
        attempt.intakeId, record, fetched: items, judged: [], decisions: [])
      attempt.finish(result.startedAt)
      return
    }
    let open = store.openProposals(of: attempt.intakeId, in: items)
    let judge = attempt.definition.judge
    let prompt = IntakePrompts.judge(
      instruction: judge.instruction, items: fresh, open: open, now: now(),
      timeZone: calendar().timeZone)
    let job = BackgroundJob.agent(
      BackgroundAgentCall(cli: judge.cli, model: judge.model, tools: [], prompt: prompt))
    let judging = Judging(record: record, fetched: items, fresh: fresh, open: open)
    attempt.current = run(job) { [weak self] judged in
      guard !attempt.cancelled else { return }
      self?.judged(judged, attempt, judging)
    }
  }

  private func judged(_ result: BackgroundRunResult, _ attempt: Attempt, _ judging: Judging) {
    var record = judging.record
    record.endedAt = result.endedAt
    var report = IntakeJudgeReport(
      commandLine: result.commandLine, ending: result.ending.text, proposed: 0, resolved: 0,
      rejected: IntakeRejections())
    defer { attempt.finish(record.startedAt) }
    switch Self.reply(result, role: "judge") {
    case .failure(let failure):
      record.judge = report
      record.failure = failure.reason
      store.recordFailure(of: attempt.intakeId, record)
    case .success(let text):
      let (decisions, rejected) = IntakePrompts.readJudge(
        text, items: judging.fresh, open: judging.open)
      report.rejected = rejected
      record.judge = report
      store.commit(
        attempt.intakeId, record, fetched: judging.fetched, judged: judging.fresh,
        decisions: decisions)
    }
  }

  private static func fetchJob(_ fetch: IntakeFetch) -> BackgroundJob {
    switch fetch.method {
    case .command(let command):
      return .command(command)
    case .agent(let agent):
      return .agent(
        BackgroundAgentCall(
          cli: agent.cli, model: agent.model, tools: agent.tools,
          prompt: IntakePrompts.fetch(request: agent.request)))
    }
  }

  /// 取得の成否。コマンドは終了コード 0、agent は終了コード 0 で最終応答があり失敗の報告でないこと。そのうえで出力を読む。
  private static func readFetch(_ result: BackgroundRunResult) -> IntakePrompts.FetchReading {
    if case .command(let stdout, let stderr) = result.output {
      guard result.ending == .exited(0) else {
        return .failed(
          failure("fetch", result.ending, detail: stderr.data), rejected: IntakeRejections())
      }
      guard let text = String(bytes: stdout.data, encoding: .utf8) else {
        return .failed("the fetch output is not UTF-8", rejected: IntakeRejections())
      }
      return IntakePrompts.readFetch(text)
    }
    switch reply(result, role: "fetch") {
    case .failure(let failure): return .failed(failure.reason, rejected: IntakeRejections())
    case .success(let text): return IntakePrompts.readFetch(text)
    }
  }

  private static func reply(_ result: BackgroundRunResult, role: String) -> Result<
    String, ReplyFailure
  > {
    guard case .agent(let reply, let stderr) = result.output, result.ending == .exited(0) else {
      var detail = Data()
      if case .agent(let reply, let stderr) = result.output {
        detail = reply.map { Data($0.text.utf8) } ?? stderr.data
      }
      return .failure(ReplyFailure(failure(role, result.ending, detail: detail)))
    }
    guard let reply else {
      return .failure(
        ReplyFailure(
          failure(role, result.ending, detail: stderr.data, what: "ended without a reply")))
    }
    guard !reply.isError else {
      return .failure(ReplyFailure("the \(role) agent reported an error: \(snippet(reply.text))"))
    }
    return .success(reply.text)
  }

  private static func failure(
    _ role: String, _ ending: BackgroundEnding, detail: Data, what: String? = nil
  ) -> String {
    let text = snippet(String(bytes: detail, encoding: .utf8) ?? "")
    let head = "the \(role) \(what ?? "ended: \(ending.text)")"
    return text.isEmpty ? head : "\(head): \(text)"
  }

  private static func snippet(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count > 500 ? String(trimmed.prefix(500)) + "…" : trimmed
  }

  private struct ReplyFailure: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
  }

  /// 判定を待っている間に持ち越すもの。
  private struct Judging {
    let record: IntakeRun
    let fetched: [IntakeItem]
    let fresh: [IntakeItem]
    let open: [IntakeProposal]
  }

  /// 走っている 1 回。止められたら、以後の結果は捨てる。
  private final class Attempt {
    let intakeId: Int
    let definition: IntakeDefinition
    let trigger: IntakeRun.Trigger
    let finish: (Date) -> Void
    var current: BackgroundRunHandle?
    var cancelled = false

    init(
      intakeId: Int, definition: IntakeDefinition, trigger: IntakeRun.Trigger,
      finish: @escaping (Date) -> Void
    ) {
      self.intakeId = intakeId
      self.definition = definition
      self.trigger = trigger
      self.finish = finish
    }
  }
}

extension BackgroundEnding {
  /// 回の記録に残す終わり方。
  var text: String {
    switch self {
    case .exited(let code): "exited \(code)"
    case .signaled(let signal): "killed by signal \(signal)"
    case .limited(.elapsed): "stopped at the time limit"
    case .limited(.idle): "stopped after producing no output for too long"
    case .limited(.output): "stopped at the output limit"
    case .stopped: "stopped"
    case .notStarted(let failure): "not started (\(failure.text))"
    case .toolsUnavailable(let tools): "tools unavailable: \(tools.joined(separator: ", "))"
    }
  }
}

extension BackgroundStartFailure {
  var text: String {
    switch self {
    case .invalid(let error): error.message
    case .agentUnsupported(let cli, let reason):
      "\(cli) cannot run in the background: \(reason.message)"
    case .agentNotFound(let cli): "\(cli) is not installed"
    case .directoryMissing(let directory): "directory missing: \(directory)"
    case .launchFailed(let code): "launch failed: \(String(cString: strerror(code)))"
    }
  }
}
