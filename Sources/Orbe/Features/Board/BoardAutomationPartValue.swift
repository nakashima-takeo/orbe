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

/// 選んだ部品のカードの値。地図に出さない部品の中身（手段・モデル・ツール・指示文・取り方・上限・制限時間・場所・回の記録）を
/// 出すのはここだけ。
struct BoardAutomationPartValue: Equatable {
  let key: String
  let role: String
  let name: String
  let running: Bool
  /// 頭の印。まだ動いていなければ nil。
  let mark: BoardRunMark?
  /// 実行・ツール・予定・取り方・入力元・出力先・未処理・制限時間・場所・次回の順。部品に無い項目は出さない。
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
    /// 「出力の形式エラー · 16:30 · 2 行」。
    let heading: String
    /// 「3 行目：link が無い」（最初の数件）。
    let lines: [String]
    /// 出し直しの結果の一言。
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
    _ automation: Automation, part key: String, text: AutomationText, running: Bool, next: Date?,
    open: Int
  ) {
    guard let node = automation.graph.node(key) else { return nil }
    let l10n = text.l10n
    let state = automation.state(key)
    self.key = key
    role = text.role(node.role)
    name = node.part.name
    self.running = running
    mark = state.runs.first.map { $0.failed ? .failure : .success }
    switch node.part.method {
    case .agent(let agent): body = agent.instruction
    case .command(let command): body = command.script
    }
    facts = Self.facts(automation, node, text: text, next: next, open: open)
    breach = state.breach.map { mark in
      Breach(
        heading: l10n.format(
          mark.lines.count == 1 ? .boardPartFormatErrorOne : .boardPartFormatErrorOther,
          text.recent(mark.at), mark.lines.count),
        lines: mark.lines.lines.map(text.line),
        outcome: l10n.string(
          mark.passed
            ? .boardPartRedonePassed : mark.redone ? .boardPartRedoneFailed : .boardPartNotRedone))
    }
    lastText = Self.lastText(state.runs, text: text)
    runs = BoardAutomationSummary.lines(state.runs, node: node, text: text)
  }

  /// 前回の報告（報告の部品）か応答（作業の部品）。文を残した最新の回から。
  private static func lastText(_ runs: [AutomationPartRun], text: AutomationText) -> LastText? {
    for run in runs {
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
    let state = automation.state(node.key)
    let separator = l10n.string(.automationListSeparator)
    var facts: [Fact] = []
    func fact(_ label: L10nKey, _ value: String, flow: BoardFlowDirection? = nil) {
      facts.append(Fact(label: label, flow: flow, value: [Segment(text: value, look: .plain)]))
    }
    switch part.method {
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
    if case .fetch(let coverage) = node.role { fact(.boardPartTake, take(coverage, state, text)) }
    if !part.inputs.isEmpty {
      fact(
        .boardPartFrom,
        part.inputs.map { graph.node($0)?.part.name ?? $0 }.joined(separator: separator),
        flow: .incoming)
    }
    switch part.destination {
    case .nextPart:
      fact(
        .boardPartTo, graph.downstream(of: node.key).map(\.part.name).joined(separator: separator),
        flow: .outgoing)
    case .taskCandidates: fact(.boardPartTo, l10n.format(.boardPartTaskCandidates, open))
    case .report: fact(.boardPartTo, BoardAutomationDetailValue.reports(automation.notify, l10n))
    case .sideEffect: fact(.boardPartTo, l10n.string(.boardPartNothing))
    }
    if !part.inputs.isEmpty {
      facts.append(
        Fact(
          label: .boardPartPending,
          flow: nil,
          value: [
            Segment(
              text: l10n.format(.boardPartCount, state.inbox),
              look: state.inbox > 0 ? .emphasized : .muted),
            Segment(text: "\u{3000}" + limit(part.inboxLimit, l10n), look: .muted),
          ]))
    }
    fact(.boardPartTimeout, l10n.format(.boardPartMinutes, node.timeoutMinutes))
    if case .command(let command) = part.method, let directory = command.directory {
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

  /// 取り方（「新着だけ（前回 16:00 以降）」「今ある分のうち、新しく現れたもの」「毎回すべて」）。
  private static func take(
    _ coverage: AutomationCoverage, _ state: AutomationPartState, _ text: AutomationText
  ) -> String {
    let l10n = text.l10n
    switch coverage {
    case .newArrivals:
      return state.succeededAt.map { l10n.format(.boardPartNewSince, text.recent($0)) }
        ?? l10n.string(.boardPartNewOnly)
    case .currentSet: return l10n.string(.boardPartCurrentSet)
    case .everything: return l10n.string(.boardPartEverything)
    }
  }

  /// 未処理の上限（「24 時間より古い分は捨てる」「上限なし」）。
  private static func limit(_ limit: AutomationPart.InboxLimit?, _ l10n: LocalizationStore)
    -> String
  {
    switch (limit?.maxAgeHours, limit?.maxItems) {
    case (let hours?, let items?): l10n.format(.boardPartLimitBoth, hours, items)
    case (let hours?, nil): l10n.format(.boardPartLimitAge, hours)
    case (nil, let items?): l10n.format(.boardPartLimitItems, items)
    case (nil, nil): l10n.string(.boardPartNoLimit)
    }
  }
}
