import Foundation

/// 選んだ部品のカードの値。地図に出さない部品の中身（手段・モデル・ツール・指示文・取得の性質・上限・回の記録）を出すのは
/// ここだけ。
struct BoardAutomationPartValue: Equatable {
  let key: String
  let role: String
  let name: String
  let look: BoardNodeLook
  /// 頭の札のモデル（省いていれば役割の既定）。コマンドは nil（札は「コマンド」）。
  let model: String?
  let tools: [String]
  let schedule: String
  let arrival: Bool
  let facts: [Fact]
  /// 指示文かコマンド。
  let body: String
  let breach: Breach?
  /// この部品の回（新しい順）。
  let runs: [BoardRunLine]

  /// 項目 1 つ（「入力」← A・B）。
  struct Fact: Equatable {
    let label: L10nKey
    let value: String
    /// 強調色で出す（1 件以上の溜まり）。
    let emphasized: Bool
  }

  /// 出力が決まりを外した印。
  struct Breach: Equatable {
    /// 「出力が決まりを外した · 10/18 13:00 · 3 行 · 出し直しで通った」。
    let summary: String
    /// 外れた行の理由（最初の数件）。
    let reasons: [String]
  }
}

extension BoardAutomationPartValue {
  /// `next` は部品が次に予定で回る時刻（止めていれば nil）。
  init?(
    _ automation: Automation, part key: String, text: AutomationText, running: Bool, next: Date?
  ) {
    guard let node = automation.graph.node(key) else { return nil }
    let l10n = text.l10n
    let part = node.part
    let state = automation.state(key)
    self.key = key
    role = text.role(node.role)
    name = part.name
    look = running ? .running : state.runs.first?.failed == true ? .failed : .idle
    schedule = text.schedule(part.trigger)
    arrival = part.trigger == .arrival
    switch part.method {
    case .agent(let agent):
      model = node.model
      tools = agent.tools
      body = agent.instruction
    case .command(let command):
      model = nil
      tools = []
      body = command.script
    }

    facts = Self.facts(automation, node, text: text, next: next)

    breach = state.breach.map { mark in
      Breach(
        summary: l10n.format(
          mark.lines.count == 1 ? .boardPartBreachOne : .boardPartBreachOther,
          text.stamp(mark.at), mark.lines.count,
          l10n.string(mark.passed ? .automationBreachPassed : .automationBreachFailed)),
        reasons: mark.lines.reasons)
    }
    runs = BoardAutomationSummary.lines(
      state.runs.map { AutomationKeyedRun(part: key, run: $0) }, name: nil, text: text)
  }

  /// 項目（入力・行の先・取得の性質・溜まりと上限・次回）。持たない項目は出さない。
  private static func facts(
    _ automation: Automation, _ node: AutomationGraph.Node, text: AutomationText, next: Date?
  ) -> [Fact] {
    let l10n = text.l10n
    let graph = automation.graph
    let part = node.part
    let key = node.key
    let state = automation.state(key)
    let separator = l10n.string(.automationListSeparator)
    var facts: [Fact] = []
    func fact(_ label: L10nKey, _ value: String, emphasized: Bool = false) {
      facts.append(Fact(label: label, value: value, emphasized: emphasized))
    }
    if !part.inputs.isEmpty {
      fact(
        .boardPartInputs,
        "← " + part.inputs.map { graph.node($0)?.part.name ?? $0 }.joined(separator: separator))
    }
    switch part.destination {
    case .nextPart:
      fact(
        .boardPartGoesTo,
        "→ " + graph.downstream(of: key).map(\.part.name).joined(separator: separator))
    case .taskCandidates: fact(.boardPartGoesTo, l10n.string(.boardOutputTaskCandidates))
    case .report: fact(.boardPartGoesTo, l10n.string(.boardOutputReport))
    case .sideEffect: fact(.boardPartGoesTo, l10n.string(.boardPartNowhere))
    }
    if let coverage = part.coverage {
      let words: L10nKey =
        switch coverage {
        case .currentSet: .boardCoverageCurrentSet
        case .newArrivals: .boardCoverageNewArrivals
        case .everything: .boardCoverageEverything
        }
      fact(.boardPartCoverage, l10n.string(words))
    }
    if !part.inputs.isEmpty {
      var limits: [String] = []
      if let hours = part.inboxLimit?.maxAgeHours {
        limits.append(l10n.format(.boardPartLimitHours, hours))
      }
      if let items = part.inboxLimit?.maxItems {
        limits.append(l10n.format(.boardPartLimitItems, items))
      }
      fact(
        .boardPartInbox,
        limits.isEmpty
          ? "\(state.inbox)"
          : l10n.format(.boardPartInboxLimit, state.inbox, limits.joined(separator: separator)),
        emphasized: state.inbox > 0)
    }
    if case .scheduled = part.trigger {
      fact(
        .boardPartNextRun,
        automation.paused ? l10n.string(.automationPaused) : next.map(text.stamp) ?? "")
    }
    return facts
  }
}
