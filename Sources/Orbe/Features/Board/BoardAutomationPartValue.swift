import Foundation

/// カードの項目の切れの見え方。
enum BoardSegmentLook: Equatable {
  case plain
  case muted
  case emphasized
}

/// 部品どうしの流れの向き（入力元は入ってくる、出力先は出ていく）。
enum BoardFlowDirection: Equatable {
  case incoming
  case outgoing
}

/// 選んだ部品のカードの値。地図に出さない部品の中身（手段・モデル・ツール・指示文・出力の性質・取り方・上限・制限時間・場所・
/// 回の記録）を出すのはここだけ。
struct BoardAutomationPartValue: Equatable {
  let id: AutomationPartID
  let role: String
  let name: String
  let running: Bool
  /// 頭の印。まだ動いていなければ nil。
  let mark: BoardRunMark?
  /// 実行・ツール・予定・出力の性質・入力元・出力先・未処理・制限時間・場所・次回の順。部品に無い項目は出さない。
  let facts: [Fact]
  /// 指示文かコマンド。
  let body: String
  let breach: Breach?
  /// 前回の報告か応答（報告と作業の部品だけ）。
  let lastText: LastText?
  /// この部品の実行履歴（新しい順）。
  let runs: [BoardRunLine]

  /// 項目 1 つ。値は見え方の違う切れの並び（「8 件」＋「上限なし」）。部品どうしをつなぐ入力元・出力先は頭に向きの矢印を置く。
  struct Fact: Equatable {
    let label: L10nKey
    let flow: BoardFlowDirection?
    let value: [Segment]
  }

  struct Segment: Equatable {
    let text: String
    let look: BoardSegmentLook
  }

  /// 出力の形式エラーの枠（部品の外した印から）。
  struct Breach: Equatable {
    /// 「出力の形式エラー · 16:30 · 2 件」。
    let heading: String
    /// 「3 件目：link が無い」（最初の数件）。
    let lines: [String]
    /// 結果の一言。
    let outcome: String
  }

  struct LastText: Equatable {
    let title: L10nKey
    let at: String
    let text: String
  }
}

extension BoardAutomationPartValue {
  /// `next` は部品が次に予定で回る時刻（止めていれば nil）、`open` はこの自動化の棚に出ている判断待ちの候補の数。
  init?(
    _ automation: Automation, part: AutomationPartID, text: AutomationText, running: Bool,
    next: Date?, open: Int
  ) {
    guard let node = automation.graph.node(part) else { return nil }
    let l10n = text.l10n
    let state = automation.state(part)
    id = part
    role = text.role(node.role)
    name = node.part.name
    self.running = running
    mark = state.runs.first.map { $0.failed ? .failure : .success }
    switch node.action.method {
    case .agent(let agent): body = agent.instruction
    case .command(let command): body = command.script
    }
    facts = Self.facts(automation, node, text: text, next: next, open: open)
    breach = state.breach.map { Self.breach($0, text: text) }
    lastText = Self.lastText(state.runs, text: text)
    runs = BoardAutomationSummary.lines(state.runs, node: node, text: text)
  }

  /// 印の回の記録から。読めない記録なら外れた件は空。
  private static func breach(_ record: AutomationRunRecord, text: AutomationText) -> Breach {
    let l10n = text.l10n
    let lines = record.run?.breach ?? AutomationRejections()
    return Breach(
      heading: l10n.format(
        lines.count == 1 ? .boardPartFormatErrorOne : .boardPartFormatErrorOther,
        text.recent(record.startedAt), lines.count),
      lines: lines.lines.map(text.line),
      outcome: l10n.string(record.failed ? .boardPartBreachFailed : .boardPartBreachPassed))
  }

  /// 前回の報告（報告の部品）か応答（作業の部品）。文を残した最新の回から。
  private static func lastText(_ runs: [AutomationRunRecord], text: AutomationText) -> LastText? {
    for run in runs.compactMap(\.run) {
      switch run.result {
      case .report(let report?):
        return LastText(title: .boardPartLastReport, at: text.recent(run.startedAt), text: report)
      case .work(let reply?, nil):
        return LastText(title: .boardPartLastReply, at: text.recent(run.startedAt), text: reply)
      default: continue
      }
    }
    return nil
  }

  private static func facts(
    _ automation: Automation, _ node: AutomationGraph.Node, text: AutomationText, next: Date?,
    open: Int
  ) -> [Fact] {
    let l10n = text.l10n
    let graph = automation.graph
    let part = node.part
    let action = node.action
    let state = automation.state(node.id)
    let separator = l10n.string(.automationListSeparator)
    var facts: [Fact] = []
    func fact(_ label: L10nKey, _ value: String, flow: BoardFlowDirection? = nil) {
      facts.append(Fact(label: label, flow: flow, value: [Segment(text: value, look: .plain)]))
    }
    switch action.method {
    case .agent(let agent):
      fact(
        .boardPartRun,
        l10n.format(.boardPartAgent, agent.cli, node.model ?? l10n.string(.boardPartDefaultModel)))
      if !agent.tools.isEmpty {
        fact(.boardPartTools, tools(agent.tools, l10n).joined(separator: separator))
      }
    case .command:
      fact(.boardPartRun, l10n.string(.boardOutputCommand))
    }
    fact(.boardPartSchedule, text.schedule(part.trigger))
    if let coverage = node.coverage {
      fact(.boardPartCoverage, self.coverage(coverage, of: node, state, text))
    }
    if !node.inputs.isEmpty {
      fact(
        .boardPartFrom,
        node.inputs.map { input(graph, $0, l10n) }.joined(separator: separator), flow: .incoming)
    }
    switch action.destination {
    case .nextPart:
      fact(
        .boardPartTo, graph.downstream(of: node.id).map(\.part.name).joined(separator: separator),
        flow: .outgoing)
    case .taskCandidates: fact(.boardPartTo, l10n.format(.boardPartTaskCandidates, open))
    case .report: fact(.boardPartTo, BoardAutomationDetailValue.reports(automation.notify, l10n))
    case .sideEffect: fact(.boardPartTo, l10n.string(.boardPartNothing))
    }
    if !node.inputs.isEmpty {
      facts.append(
        Fact(
          label: .boardPending,
          flow: nil,
          value: [
            Segment(
              text: l10n.format(.boardPartCount, state.pending.count),
              look: state.pending.count > 0 ? .emphasized : .muted),
            Segment(text: "\u{3000}" + limit(part.maxItems, l10n), look: .muted),
          ]))
    }
    fact(.boardPartTimeout, l10n.format(.boardPartMinutes, node.timeoutMinutes))
    if case .command(let command) = action.method, let directory = command.directory {
      fact(.boardPartDirectory, directory)
    }
    if case .scheduled = part.trigger {
      fact(
        .boardPartNext,
        automation.paused ? l10n.string(.automationPaused) : next.map(text.stamp) ?? "")
    }
    return facts
  }

  /// 同じ表示になるツール（同じサーバーの MCP、同じコマンドの Bash 規則）は、最初の 1 つだけを残す。
  private static func tools(_ rules: [String], _ l10n: LocalizationStore) -> [String] {
    var seen: Set<String> = []
    return rules.map { tool(text: $0, l10n) }.filter { seen.insert($0).inserted }
  }

  /// MCP のツールは「<サーバー名の頭を大文字に>（MCP）」、`Bash(git:*)` は「git コマンド」。どちらでもなければ規則のまま。
  private static func tool(text rule: String, _ l10n: LocalizationStore) -> String {
    if rule.hasPrefix("mcp__") {
      let name = server(rule.dropFirst(5).components(separatedBy: "__")[0])
      return l10n.format(.boardPartToolMCP, name.prefix(1).uppercased() + name.dropFirst())
    }
    if rule.hasPrefix("Bash("), rule.hasSuffix(")") {
      let body = rule.dropFirst(5).dropLast()
      let command = body.hasSuffix(":*") ? body.dropLast(2) : body
      return l10n.format(.boardPartToolCommand, command.trimmingCharacters(in: .whitespaces))
    }
    return rule
  }

  /// Claude Code がサーバー名の頭に付ける出どころ（claude.ai のコネクタの `claude_ai_`、プラグインの `plugin_<プラグイン名>_`）を
  /// 落とす。
  private static func server(_ name: String) -> String {
    if name.hasPrefix("claude_ai_") { return String(name.dropFirst("claude_ai_".count)) }
    if name.hasPrefix("plugin_"),
      let separator = name.dropFirst("plugin_".count).firstIndex(of: "_")
    {
      return String(name[name.index(after: separator)...])
    }
    return name
  }

  /// 入力 1 つ（「取得」「取得（毎回すべて・24 時間まで）」）。
  private static func input(
    _ graph: AutomationGraph, _ edge: AutomationPartEdge, _ l10n: LocalizationStore
  ) -> String {
    let name = graph.node(edge.from)?.part.name ?? "\(edge.from)"
    let notes =
      (edge.take == .all ? [l10n.string(.boardPartTakeAll)] : [])
      + (edge.maxAgeHours.map { [l10n.format(.boardPartMaxAge, $0)] } ?? [])
    guard !notes.isEmpty else { return name }
    return l10n.format(
      .automationWithOriginal, name,
      notes.joined(separator: l10n.string(.automationListSeparator)))
  }

  /// 出力の性質（「今の集合」「出来事の流れ」）。出来事の流れの取得は、前回成功の目印から取ることを添える（「出来事の流れ
  /// （前回 16:00 以降を取る）」）。
  private static func coverage(
    _ coverage: AutomationCoverage, of node: AutomationGraph.Node, _ state: AutomationPartState,
    _ text: AutomationText
  ) -> String {
    let l10n = text.l10n
    switch coverage {
    case .currentSet: return l10n.string(.boardPartCurrentSet)
    case .newArrivals:
      guard node.role == .fetch, let since = state.succeededAt else {
        return l10n.string(.boardPartEventStream)
      }
      return l10n.format(.boardPartEventStreamSince, text.recent(since))
    }
  }

  /// 1 回に取る件数の上限（「30 件を超えた古い分は捨てる」「上限なし」）。古さの上限は入力ごとに入力元へ添える。
  private static func limit(_ maxItems: Int?, _ l10n: LocalizationStore) -> String {
    maxItems.map { l10n.format(.boardPartLimitItems, $0) } ?? l10n.string(.boardPartNoLimit)
  }
}
