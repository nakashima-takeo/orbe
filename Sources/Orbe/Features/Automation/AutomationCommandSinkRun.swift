import Foundation

/// 出力先のコマンドの 1 回。届いた行をそのまま標準入力で渡し、回の ID を環境変数 `ORBE_RUN_ID` で渡す。項目の同一性は
/// 確かめない（id の当て直しはタスク候補の規則で、コマンドは行をそのまま受ける役）。
final class AutomationCommandSinkRun: AutomationSinkRun {
  /// 見直すと、指示文を直しただけで今の集合の全件がコマンドに渡り直し、副作用が二重に起きる。
  static let reviewsAfterRework = false

  private let sink: AutomationSinkCommand
  private let runId: String
  /// 行を作るもの（取得元か段）があるか。無ければ届いた行が 0 でも走る。
  private let producesRows: Bool
  private let run: BackgroundScheduler.Run
  private var report: AutomationCommandReport?

  init(
    _ sink: AutomationSinkCommand, runId: String, producesRows: Bool,
    run: @escaping BackgroundScheduler.Run
  ) {
    self.sink = sink
    self.runId = runId
    self.producesRows = producesRows
    self.run = run
  }

  /// 要件。コマンドは空でなく作業ディレクトリは絶対パス、上限は 1〜60 分。取得元も段も任意。
  static func check(_ sink: AutomationSinkCommand) throws(AutomationError) {
    do throws(BackgroundJobError) {
      try BackgroundJob.command(sink.command).validate()
    } catch {
      throw .invalid("sink: \(error.message)")
    }
    if let minutes = sink.timeoutMinutes, !AutomationSinkCommand.timeoutRange.contains(minutes) {
      throw .invalid(
        "sink: timeoutMinutes must be \(AutomationSinkCommand.timeoutRange.lowerBound) to "
          + "\(AutomationSinkCommand.timeoutRange.upperBound)")
    }
  }

  func admit(_ items: [AutomationItem], fetched: [AutomationItem]) -> [AutomationItem] { items }

  func prepare(_ rows: [String]) -> [String] { rows }

  /// コマンドにとって最後の段は中間の段と同じ役なので、中間の段の依頼文を使う。
  func prompt(instruction: String, rows: [String], now: Date, timeZone: TimeZone) -> String {
    AutomationPrompts.step(instruction: instruction, rows: rows, now: now, timeZone: timeZone)
  }

  /// 中間の段と同じく、出力があったのに 1 行も読めなければ回の失敗。
  func read(_ text: String) -> AutomationSinkReading<[String]> {
    let (rows, rejected) = AutomationPrompts.readRows(text)
    guard !rows.isEmpty || rejected.count == 0 else {
      return .failed("every line of the output of the last step was malformed", rejected: rejected)
    }
    return .output(rows.map(\.text), count: rows.count, rejected: rejected)
  }

  func deliver(_ rows: [String], completion: @escaping (AutomationSinkFailure?) -> Void)
    -> BackgroundRunHandle
  {
    guard !rows.isEmpty || !producesRows else {
      completion(nil)
      return BackgroundRunHandle {}
    }
    let seconds = TimeInterval(sink.resolvedTimeoutMinutes * 60)
    let job = BackgroundJob(
      work: .command(
        sink.command,
        BackgroundInput(
          stdin: Data(rows.map { $0 + "\n" }.joined().utf8), environment: ["ORBE_RUN_ID": runId])),
      limits: BackgroundLimits(
        elapsed: seconds, idle: seconds, output: BackgroundLimits.command.output,
        stderr: BackgroundLimits.command.stderr))
    return run(job) { result in
      let report = AutomationCommandReport(
        commandLine: result.commandLine, ending: result.ending.text, count: rows.count)
      guard result.ending == .exited(0) else {
        var stderr = Data()
        if case .command(_, let captured) = result.output { stderr = captured.data }
        completion(
          AutomationSinkFailure(
            reason: AutomationRunOutput.failure("sink command", result.ending, detail: stderr),
            report: .command(report)))
        return
      }
      self.report = report
      completion(nil)
    }
  }

  func commit(
    _ output: [String]?, into book: inout AutomationProposalBook, automations: [Automation],
    endedAt: Date
  ) -> AutomationSinkReport? {
    report.map(AutomationSinkReport.command)
  }
}
