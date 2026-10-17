import Foundation

/// 役割ごとの出力の読み。失敗の文は今の自動化と同じ形で、役の語は `part "<鍵>"`。
extension AutomationPartPass {
  static func read(_ result: BackgroundRunResult, _ node: AutomationGraph.Node, _ input: Input)
    -> Outcome
  {
    let word = "part \"\(node.key)\""
    switch input {
    case .fetch(_, let lastOutput):
      return reading(result, word) { fetched($0, result, node, lastOutput: lastOutput) }
    case .process(let rows):
      return reading(result, word) { processed($0, result, rows, word) }
    case .judge(let rows, let choices):
      return reading(result, word) { judged($0, result, rows, choices) }
    case .report:
      return reading(result, word) { text in
        let report =
          AutomationPrompts.nothing(text) == nil ? AutomationReportSinkRun.kept(text) : nil
        return .succeeded(.report(report), execution(result, count: report == nil ? 0 : 1))
      }
    case .work:
      return reading(result, word) { worked($0, result, word) }
    case .sideEffect(let rows, _):
      return sideEffected(result, count: rows.count, word)
    }
  }

  /// 手段の出力を文として受けてから読む。
  private static func reading(
    _ result: BackgroundRunResult, _ word: String, _ body: (String) -> Outcome
  ) -> Outcome {
    switch AutomationRunOutput.text(result, role: word) {
    case .failure(let failure): .failed(failure.reason, execution(result))
    case .success(let text): body(text)
    }
  }

  private static func execution(
    _ result: BackgroundRunResult, count: Int = 0,
    rejected: AutomationRejections = AutomationRejections()
  ) -> Execution {
    Execution(
      commandLine: result.commandLine, ending: result.ending.text, count: count, rejected: rejected)
  }

  /// 前回の出力に無い項目（毎回全件なら全部）を、`id` に部品の鍵の接頭を付けた行にする。出どころは元の項目のまま持つ。
  private static func fetched(
    _ text: String, _ result: BackgroundRunResult, _ node: AutomationGraph.Node,
    lastOutput: Set<String>
  ) -> Outcome {
    switch AutomationPrompts.readFetch(text) {
    case .failed(let reason, let rejected):
      return .failed(reason, execution(result, rejected: rejected))
    case .items(let items, let rejected):
      let fresh =
        node.role == .fetch(.everything) ? items : items.filter { !lastOutput.contains($0.id) }
      let rows = fresh.map { item in
        let id = "\(node.key):\(item.id)"
        return AutomationPartRow(
          id: id,
          text: AutomationPrompts.row(
            AutomationItem(id: id, link: item.link, body: item.body, time: item.time)),
          origin: AutomationOrigin(part: node.key, item: item))
      }
      return .succeeded(
        .fetch(rows: rows, lastOutput: items.map { AutomationSeen(id: $0.id, link: $0.link) }),
        execution(result, count: items.count, rejected: rejected))
    }
  }

  /// `id` の無い行が 1 行でもあれば、何も渡さずに失敗にする。出どころは `id` で入力の行と照らして引き継ぐ。
  private static func processed(
    _ text: String, _ result: BackgroundRunResult, _ rows: [AutomationPartRow], _ word: String
  ) -> Outcome {
    let reading = AutomationPrompts.readStep(text, step: word)
    let execution = execution(result, count: reading.rows.count, rejected: reading.rejected)
    if let failure = reading.failure { return .failed(failure, execution) }
    let origins = Dictionary(
      rows.compactMap { row in row.origin.map { (row.id, $0) } }, uniquingKeysWith: { $1 })
    var passed: [AutomationPartRow] = []
    for row in reading.rows {
      guard let id = AutomationPrompts.id(of: row.text) else {
        return .failed("line \(row.line) of the output of \(word) has no id", execution)
      }
      passed.append(AutomationPartRow(id: id, text: row.text, origin: origins[id]))
    }
    return .succeeded(.process(passed), execution)
  }

  /// 候補の案は取った行の `id` を指すものだけを受け、指した行の出どころを付ける。全行が形違いでも失敗にせず、候補なしとする。
  private static func judged(
    _ text: String, _ result: BackgroundRunResult, _ rows: [AutomationSourcedRow],
    _ choices: AutomationJudgeChoices
  ) -> Outcome {
    let (lines, malformed) = AutomationPrompts.readRows(text)
    let origins = Dictionary(rows.map { ($0.id, $0.origin) }, uniquingKeysWith: { $1 })
    let (decisions, rejected) = AutomationPrompts.readJudge(
      lines, itemIds: Set(origins.keys), choices: choices)
    var proposals: [Proposal] = []
    var resolved: [String] = []
    for decision in decisions {
      switch decision {
      case .propose(let itemId, let title, let due, let workspace):
        guard let origin = origins[itemId] else { continue }
        proposals.append(Proposal(origin: origin, title: title, due: due, workspace: workspace))
      case .resolve(let link):
        resolved.append(link)
      }
    }
    return .succeeded(
      .judge(proposals: proposals, resolved: resolved, rejected: rejected),
      execution(result, count: lines.count, rejected: malformed))
  }

  /// 全体が `{"error": …}` の 1 行なら失敗、最後の空でない行が `{"nothing": …}` なら何もしなかった回、ほかは報告の文。
  private static func worked(_ text: String, _ result: BackgroundRunResult, _ word: String)
    -> Outcome
  {
    if let error = AutomationPrompts.sinkAgentError(text) {
      return .failed("the \(word) reported an error: \(error)", execution(result))
    }
    if let nothing = AutomationPrompts.nothing(text) {
      return .succeeded(.work(.nothing(nothing)), execution(result))
    }
    let report = AutomationReportSinkRun.kept(text)
    return .succeeded(.work(.done(report)), execution(result, count: report == nil ? 0 : 1))
  }

  /// 終了コードだけを見て、標準出力は読まない。
  private static func sideEffected(_ result: BackgroundRunResult, count: Int, _ word: String)
    -> Outcome
  {
    let execution = execution(result, count: count)
    guard result.ending == .exited(0) else {
      var stderr = Data()
      if case .command(_, let captured) = result.output { stderr = captured.data }
      return .failed(AutomationRunOutput.failure(word, result.ending, detail: stderr), execution)
    }
    return .succeeded(.sideEffect, execution)
  }
}
