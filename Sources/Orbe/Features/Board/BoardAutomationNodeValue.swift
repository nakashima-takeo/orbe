import Foundation

/// カードの項目の切れの見え方。
enum BoardSegmentLook: Equatable {
  case plain
  case muted
  case emphasized
}

/// 選んだノードのカードの値。地図に出さないノードの中身（手段・モデル・ツール・指示文・保存・取り方・上限・制限時間・作業ディレクトリ・
/// 回の記録）を出すのはここだけ。
struct BoardAutomationNodeValue: Equatable {
  let id: AutomationNodeID
  let role: String
  let name: String
  let running: Bool
  /// 頭の印。まだ動いていなければ nil。
  let mark: BoardRunMark?
  /// 実行方法・ツール・トリガー・保存・入力元・出力先・未処理・制限時間・作業ディレクトリ・次回の順。ノードに無い項目は出さない。
  /// 出力先はノードの外の行き場所（タスク候補・報告の出し先など）だけで、後ろのノードへ渡す取得・処理には出さない。
  let facts: [Fact]
  /// 指示文かコマンド。
  let body: String
  let breach: Breach?
  /// 前回の報告か応答（報告と作業のノードだけ）。
  let lastText: LastText?
  /// このノードの実行履歴（新しい順）。
  let runs: [BoardRunLine]

  /// 項目 1 つ。値は見え方の違う切れの並び（「8 件」＋「上限なし」）。入力元は頭に向きの矢印を置く。
  struct Fact: Equatable {
    let label: L10nKey
    let incoming: Bool
    let value: [Segment]
  }

  struct Segment: Equatable {
    let text: String
    let look: BoardSegmentLook
  }

  /// 出力の形式エラーの枠（ノードの外した印から）。
  struct Breach: Equatable {
    /// 「出力の形式エラー · 16:30 · 2 件」。
    let heading: String
    /// 「3 件目：link がありません」（最初の数件）。
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

extension BoardAutomationNodeValue {
  /// `next` はノードが次に予定で回る時刻（止めていれば nil）、`open` はこの自動化の棚に出ている判断待ちの候補の数。
  init?(
    _ automation: Automation, nodeId: AutomationNodeID, text: AutomationText, running: Bool,
    next: Date?, open: Int
  ) {
    guard let node = automation.graph.node(nodeId) else { return nil }
    let l10n = text.l10n
    let state = automation.state(nodeId)
    id = nodeId
    role = text.role(node.role)
    name = node.entity.name
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
        lines.count == 1 ? .boardNodeFormatErrorOne : .boardNodeFormatErrorOther,
        text.recent(record.startedAt), lines.count),
      lines: lines.lines.map(text.line),
      outcome: l10n.string(record.failed ? .boardNodeBreachFailed : .boardNodeBreachPassed))
  }

  /// 前回の報告（報告のノード）か応答（作業のノード）。文を残した最新の回から。
  private static func lastText(_ runs: [AutomationRunRecord], text: AutomationText) -> LastText? {
    for run in runs.compactMap(\.run) {
      switch run.result {
      case .report(let report?):
        return LastText(title: .boardNodeLastReport, at: text.recent(run.startedAt), text: report)
      case .work(let reply?, nil):
        return LastText(title: .boardNodeLastReply, at: text.recent(run.startedAt), text: reply)
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
    let entity = node.entity
    let action = node.action
    let state = automation.state(node.id)
    let separator = l10n.string(.automationListSeparator)
    var facts: [Fact] = []
    func fact(_ label: L10nKey, _ value: String, incoming: Bool = false) {
      facts.append(
        Fact(label: label, incoming: incoming, value: [Segment(text: value, look: .plain)]))
    }
    switch action.method {
    case .agent(let agent):
      fact(
        .boardNodeMethod,
        l10n.format(.boardNodeAgent, agent.cli, node.model ?? l10n.string(.boardNodeDefaultModel)))
      if !agent.tools.isEmpty {
        fact(.boardNodeTools, tools(agent.tools, l10n).joined(separator: separator))
      }
    case .command:
      fact(.boardNodeMethod, l10n.string(.boardNodeMethodCommand))
    }
    fact(.boardNodeTrigger, text.schedule(entity.trigger))
    if let coverage = node.coverage {
      fact(.boardNodeSaving, self.coverage(coverage, of: node, state, text))
    }
    if !node.inputs.isEmpty {
      fact(
        .boardNodeFrom,
        node.inputs.map { input(graph, $0, l10n) }.joined(separator: separator), incoming: true)
    }
    switch action.destination {
    case .nextNode: break
    case .taskCandidates: fact(.boardNodeDestination, l10n.format(.boardNodeTaskCandidates, open))
    case .report:
      fact(.boardNodeDestination, BoardAutomationDetailValue.reports(automation.notify, l10n))
    case .sideEffect: fact(.boardNodeDestination, l10n.string(.boardNodeNothing))
    }
    if !node.inputs.isEmpty {
      facts.append(pending(state.pending, maxItems: entity.maxItems, l10n))
    }
    fact(.boardNodeTimeout, l10n.format(.boardNodeMinutes, node.timeoutMinutes))
    if case .command(let command) = action.method, let directory = command.directory {
      fact(.boardNodeDirectory, directory)
    }
    if case .scheduled = entity.trigger {
      fact(
        .boardNodeNext,
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
      return l10n.format(.boardNodeToolMCP, name.prefix(1).uppercased() + name.dropFirst())
    }
    if rule.hasPrefix("Bash("), rule.hasSuffix(")") {
      let body = rule.dropFirst(5).dropLast()
      let command = body.hasSuffix(":*") ? body.dropLast(2) : body
      return l10n.format(.boardNodeToolCommand, command.trimmingCharacters(in: .whitespaces))
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

  /// 入力 1 つ（「取得」「取得（毎回全件・24 時間以内）」）。
  private static func input(
    _ graph: AutomationGraph, _ edge: AutomationNodeEdge, _ l10n: LocalizationStore
  ) -> String {
    let name = graph.node(edge.from)?.entity.name ?? "\(edge.from)"
    let notes =
      (edge.take == .all ? [l10n.string(.boardNodeTakeAll)] : [])
      + (edge.maxAgeHours.map { [l10n.format(.boardNodeMaxAge, $0)] } ?? [])
    guard !notes.isEmpty else { return name }
    return l10n.format(
      .automationWithOriginal, name,
      notes.joined(separator: l10n.string(.automationListSeparator)))
  }

  /// ノードが出した行の保存の仕方（「上書き」「追記」）。追記の取得は、前回成功の目印から取ることを添える（「追記（前回 16:00 より後を
  /// 取る）」）。
  private static func coverage(
    _ coverage: AutomationCoverage, of node: AutomationGraph.Node, _ state: AutomationNodeState,
    _ text: AutomationText
  ) -> String {
    let l10n = text.l10n
    switch coverage {
    case .currentSet: return l10n.string(.boardNodeOverwrite)
    case .newArrivals:
      guard node.role == .fetch, let since = state.succeededAt else {
        return l10n.string(.boardNodeAppend)
      }
      return l10n.format(.boardNodeAppendSince, text.recent(since))
    }
  }

  /// 未処理（「8 件」＋1 回に取る件数の上限）。
  private static func pending(
    _ pending: AutomationPending, maxItems: Int?, _ l10n: LocalizationStore
  ) -> Fact {
    Fact(
      label: .boardPending, incoming: false,
      value: [
        Segment(
          text: l10n.format(.boardNodeCount, pending.count),
          look: pending.count > 0 ? .emphasized : .muted),
        Segment(text: "\u{3000}" + limit(maxItems, l10n), look: .muted),
      ])
  }

  /// 1 回に取る件数の上限（「上限 30 件（超過分は古い順に破棄）」「上限なし」）。古さの上限は入力ごとに入力元へ添える。
  private static func limit(_ maxItems: Int?, _ l10n: LocalizationStore) -> String {
    maxItems.map { l10n.format(.boardNodeLimitItems, $0) } ?? l10n.string(.boardNodeNoLimit)
  }
}
