import Foundation

/// 出力先の agent の 1 回。届いた行は門で「起こすか」を決めるだけで、読んだ出力は起こすかの判断しか持たない——外から届いた
/// 文面を、ツールを持つ agent の依頼文へ型の上で運ばないため。起こしたら最終応答を報告と同じく回の結果として残す。
final class AutomationAgentSinkRun: AutomationSinkRun {
  /// 見直すと、指示文を直しただけで agent が起き直し、副作用が二重に起きる。
  static let reviewsAfterRework = false

  private let sink: AutomationSinkAgent
  private let gate: AutomationRowGate
  private let run: BackgroundScheduler.Run
  private let now: () -> Date
  private let calendar: () -> Calendar
  private var report: AutomationAgentReport?

  init(
    _ sink: AutomationSinkAgent, gate: AutomationRowGate, run: @escaping BackgroundScheduler.Run,
    now: @escaping () -> Date, calendar: @escaping () -> Calendar
  ) {
    self.sink = sink
    self.gate = gate
    self.run = run
    self.now = now
    self.calendar = calendar
  }

  /// 要件。ツールは 1 つ以上で、どれも MCP のツールの完全名か `Bash(<コマンドの接頭>:*)`。依頼文は空でない。取得元も段も任意。
  /// CLI とモデルは段・取得元と同じ規則で `AutomationStore` が見る。
  static func check(_ sink: AutomationSinkAgent) throws(AutomationError) {
    guard !sink.tools.isEmpty else { throw .invalid("sink: tools are empty") }
    if let tool = sink.tools.first(where: { !AutomationStore.isMCPToolName($0) && !isBashRule($0) })
    {
      throw .invalid(
        "sink: \(tool) is neither a full MCP tool name (mcp__<server>__<tool>) nor a Bash rule "
          + "(Bash(<command prefix>:*)); other built-in tools, whole servers and wildcards are refused"
      )
    }
    guard !sink.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw .invalid("sink: request is empty")
    }
  }

  /// `Bash(<接頭>:*)`。接頭は空白だけでなく、`,`（`--allowedTools` の区切り）・`(`・`)`・`*`（接頭の外の一致を許す）・制御文字を
  /// 含まない。
  private static func isBashRule(_ rule: String) -> Bool {
    guard rule.hasPrefix("Bash("), rule.hasSuffix(":*)") else { return false }
    let prefix = rule.dropFirst("Bash(".count).dropLast(":*)".count)
    guard !prefix.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
    return !prefix.unicodeScalars.contains {
      ",()*".unicodeScalars.contains($0) || CharacterSet.controlCharacters.contains($0)
    }
  }

  func admit(_ items: [AutomationItem], fetched: [AutomationItem]) -> [AutomationItem] { items }

  func prepare(_ rows: [String]) -> [String] { rows }

  /// agent にとって最後の段は起こすかを決める中間の段と同じ役なので、中間の段の依頼文を使う。
  func prompt(instruction: String, rows: [String], now: Date, timeZone: TimeZone) -> String {
    AutomationPrompts.step(instruction: instruction, rows: rows, now: now, timeZone: timeZone)
  }

  func read(_ text: String) -> AutomationSinkReading<Bool> {
    switch gate.read(text) {
    case .failed(let reason, let rejected): .failed(reason, rejected: rejected)
    case .output(let rows, let count, let rejected):
      .output(gate.opens(rows), count: count, rejected: rejected)
    }
  }

  func deliver(_ opens: Bool, completion: @escaping (AutomationSinkFailure?) -> Void)
    -> BackgroundRunHandle
  {
    guard opens else {
      completion(nil)
      return BackgroundRunHandle {}
    }
    let call = BackgroundAgentCall(
      cli: sink.cli, model: sink.resolvedModel, tools: sink.tools,
      prompt: AutomationPrompts.sinkAgent(
        request: sink.request, now: now(), timeZone: calendar().timeZone))
    return run(.agent(call)) { result in
      var report = AutomationAgentReport(
        commandLine: result.commandLine, ending: result.ending.text)
      let reply: String
      switch AutomationRunOutput.text(result, role: "sink") {
      case .failure(let failure):
        completion(AutomationSinkFailure(reason: failure.reason, report: .agent(report)))
        return
      case .success(let text): reply = text
      }
      if let error = AutomationPrompts.sinkAgentError(reply) {
        completion(
          AutomationSinkFailure(
            reason: "the sink agent reported an error: \(error)", report: .agent(report)))
        return
      }
      if let nothing = AutomationPrompts.nothing(reply) {
        report.nothing = nothing
      } else {
        report.text = AutomationReportSinkRun.kept(reply)
      }
      self.report = report
      completion(nil)
    }
  }

  func commit(
    _ output: Bool?, into book: inout AutomationProposalBook, automations: [Automation],
    endedAt: Date
  ) -> AutomationSinkReport? {
    report.map(AutomationSinkReport.agent)
  }
}
