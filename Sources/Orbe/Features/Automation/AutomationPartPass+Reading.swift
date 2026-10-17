import Foundation

/// 役割ごとの出力の読み。失敗の文は今の自動化と同じ形で、役の語は `part "<鍵>"`。
extension AutomationPartPass {
  /// 1 つの呼び出しの出力を読んだもの。`lines` は受け付けなかった行で、行を出す部品（取得・処理・判定）だけが持つ。1 行でも
  /// あれば決まりを外した出力で、`Output` は使わない。
  enum Reading {
    case failed(String)
    case read(Output, count: Int, lines: [AutomationBrokenLine])
  }

  static func read(_ result: BackgroundRunResult, _ node: AutomationGraph.Node, _ input: Input)
    -> Reading
  {
    let word = word(node)
    switch input {
    case .fetch(_, let lastOutput):
      return reading(result, word) { fetched($0, node, lastOutput: lastOutput, word) }
    case .process(let rows, let feedsJudge):
      return reading(result, word) { processed($0, rows, feedsJudge: feedsJudge) }
    case .judge(let rows, let choices):
      return reading(result, word) { judged($0, rows, choices) }
    case .report:
      return reading(result, word) { text in
        let report =
          AutomationPrompts.nothing(text) == nil ? AutomationReportSinkRun.kept(text) : nil
        return .read(.report(report), count: report == nil ? 0 : 1, lines: [])
      }
    case .work:
      return reading(result, word) { worked($0, word) }
    case .sideEffect(let rows, _):
      return sideEffected(result, count: rows.count, word)
    }
  }

  /// 「the output of part "<鍵>" broke the rules: line <n>: <理由>」。最初の外れた行を言う。
  static func broke(_ node: AutomationGraph.Node, _ lines: [AutomationBrokenLine]) -> String {
    "the output of \(word(node)) broke the rules: \(lines[0].text)"
  }

  private static func word(_ node: AutomationGraph.Node) -> String {
    "part \"\(node.key)\""
  }

  /// 手段の出力を文として受けてから読む。
  private static func reading(
    _ result: BackgroundRunResult, _ word: String, _ body: (String) -> Reading
  ) -> Reading {
    switch AutomationRunOutput.text(result, role: word) {
    case .failure(let failure): .failed(failure.reason)
    case .success(let text): body(text)
    }
  }

  /// `{"error": …}` の行は申告の失敗。項目として読めない行と、同じ `id` の 2 つ目の行は外れた行。前回の出力に無い項目
  /// （毎回全件なら全部）を、`id` に部品の鍵の接頭を付けた行にする。出どころは元の項目のまま持つ。
  private static func fetched(
    _ text: String, _ node: AutomationGraph.Node, lastOutput: Set<String>, _ word: String
  ) -> Reading {
    if let error = AutomationPrompts.reportedError(in: text) {
      return .failed("the \(word) reported an error: \(error)")
    }
    let read = JSONLines<AutomationItem>(text)
    var lines = read.rejected.map { AutomationBrokenLine(line: $0.line, reason: $0.reason.text) }
    var ids = Set<String>()
    var items: [AutomationItem] = []
    for accepted in read.accepted {
      guard ids.insert(accepted.item.id).inserted else {
        lines.append(
          AutomationBrokenLine(line: accepted.line, reason: "id \(accepted.item.id) appeared twice")
        )
        continue
      }
      items.append(accepted.item)
    }
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
    return .read(
      .fetch(rows: rows, lastOutput: items.map { AutomationSeen(id: $0.id, link: $0.link) }),
      count: items.count, lines: lines.sorted { $0.line < $1.line })
  }

  /// 最後の空でない行が `{"nothing": …}` で `id` を持つ行が無ければ、前置きの文ごと 0 行。出どころは `id` で入力の行と
  /// 照らして引き継ぐ。`id` の無い行・同じ `id` の 2 つ目の行・項目と一緒に出た nothing の行・判定へ渡すときの照らせない行は
  /// 外れた行。
  private static func processed(
    _ text: String, _ input: [AutomationPartRow], feedsJudge: Bool
  ) -> Reading {
    var (rows, lines) = AutomationPrompts.objectRows(text)
    if AutomationPrompts.nothing(text) != nil, let marker = rows.popLast() {
      guard rows.contains(where: { AutomationPrompts.id(of: $0.text) != nil }) else {
        return .read(.process([]), count: 0, lines: [])
      }
      lines.append(
        AutomationBrokenLine(line: marker.line, reason: "a nothing line alongside items"))
    }
    let origins = Dictionary(
      input.compactMap { row in row.origin.map { (row.id, $0) } }, uniquingKeysWith: { $1 })
    var ids = Set<String>()
    var passed: [AutomationPartRow] = []
    for row in rows {
      guard let id = AutomationPrompts.id(of: row.text) else {
        lines.append(AutomationBrokenLine(line: row.line, reason: "missing id"))
        continue
      }
      guard ids.insert(id).inserted else {
        lines.append(AutomationBrokenLine(line: row.line, reason: "id \(id) appeared twice"))
        continue
      }
      guard !feedsJudge || origins[id] != nil else {
        lines.append(
          AutomationBrokenLine(line: row.line, reason: "id \(id) is not the id of an input item"))
        continue
      }
      passed.append(AutomationPartRow(id: id, text: row.text, origin: origins[id]))
    }
    return .read(.process(passed), count: rows.count, lines: lines.sorted { $0.line < $1.line })
  }

  /// 候補の案は取った行の `id` を指すものだけを受け、指した行の出どころを付ける。受けられない行はどれも外れた行。
  private static func judged(
    _ text: String, _ rows: [AutomationSourcedRow], _ choices: AutomationJudgeChoices
  ) -> Reading {
    let (objects, malformed) = AutomationPrompts.objectRows(text)
    let origins = Dictionary(rows.map { ($0.id, $0.origin) }, uniquingKeysWith: { $1 })
    var lines = malformed
    var proposals: [Proposal] = []
    var resolved: [String] = []
    for (row, reading) in AutomationPrompts.judgeRows(
      objects, itemIds: Set(origins.keys), choices: choices)
    {
      switch reading {
      case .success(.propose(let itemId, let title, let due, let workspace)):
        guard let origin = origins[itemId] else { continue }
        proposals.append(Proposal(origin: origin, title: title, due: due, workspace: workspace))
      case .success(.resolve(let link)):
        resolved.append(link)
      case .failure(.malformed(let reason)), .failure(.refused(let reason)):
        lines.append(AutomationBrokenLine(line: row.line, reason: reason))
      }
    }
    return .read(
      .judge(proposals: proposals, resolved: resolved), count: objects.count,
      lines: lines.sorted { $0.line < $1.line })
  }

  /// 全体が `{"error": …}` の 1 行なら失敗、最後の空でない行が `{"nothing": …}` なら何もしなかった回、ほかは報告の文。
  private static func worked(_ text: String, _ word: String) -> Reading {
    if let error = AutomationPrompts.sinkAgentError(text) {
      return .failed("the \(word) reported an error: \(error)")
    }
    if let nothing = AutomationPrompts.nothing(text) {
      return .read(.work(.nothing(nothing)), count: 0, lines: [])
    }
    let report = AutomationReportSinkRun.kept(text)
    return .read(.work(.done(report)), count: report == nil ? 0 : 1, lines: [])
  }

  /// 終了コードだけを見て、標準出力は読まない。
  private static func sideEffected(_ result: BackgroundRunResult, count: Int, _ word: String)
    -> Reading
  {
    guard result.ending == .exited(0) else {
      var stderr = Data()
      if case .command(_, let captured) = result.output { stderr = captured.data }
      return .failed(AutomationRunOutput.failure(word, result.ending, detail: stderr))
    }
    return .read(.sideEffect, count: count, lines: [])
  }
}
