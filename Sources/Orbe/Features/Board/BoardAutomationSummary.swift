import Foundation

/// 流れの段の役割。点の形と線の描き分けが役割で決まる。
enum BoardFlowRole: Equatable {
  case trigger
  case source
  /// Orbe が挟む段（既に見たものを除く）。
  case orbe
  case step(Int)
  case output
}

/// 段の手段の札。
enum BoardFlowMeans: Equatable {
  case command(String)
  case model(String)
}

/// 流れの段 1 つ。文言まで解いた描画用の値。
struct BoardFlowNode: Equatable {
  let role: BoardFlowRole
  var title = ""
  var means: BoardFlowMeans?
  /// 実行されるとおりの原文（コマンド・依頼文・指示文）。切らずに全文を出す——承認なしで裏で走るものを、いつも確かめられるため。
  var source: String?
  var tools: [String] = []
  var note: String?
  /// 前回の回でこの段を出た件数。前回が届かなかった段は nil。
  var count: Int?
}

/// 回の区分。文言に依らず、回の記録だけから決まる。
enum BoardRunTone: Equatable {
  /// 出力先へ何かを出した。
  case produced
  /// 何も出さなかった。
  case quiet
  case failed
}

/// 実行履歴の 1 行。
struct BoardRunLine: Equatable {
  /// 「16:40」「10/3 9:00 今すぐ」。
  let at: String
  let result: String
  let tone: BoardRunTone
}

/// 自動化 1 つをボードの描画用の値へ読み替えたもの。定義と回の記録の形に依るのはこのファイルだけで、ボードのビューはこの値と
/// 立ち位置だけを読む——定義の形が変わったとき、直すのがここだけで済むため。
///
/// 段の並びは「トリガー → 取得元 → 既に見たものを除く → 処理 1..n → 出力先」。取得元の無い自動化は、既に見たものを除く段も
/// 持たない。
struct BoardAutomationSummary: Equatable {
  /// 出力先の種類の名前（一覧の 2 行目）。
  let output: String
  /// いつ（一覧の 2 行目・トリガーの段）。
  let when: String
  let nodes: [BoardFlowNode]
  /// 新しい順。
  let runs: [BoardRunLine]
  /// 帯。古い回が左。
  let strip: [BoardRunTone]
  /// 一覧の右端の、最新の回の文（「16:40 に 2件を追加」「13:00 に失敗」）。まだ回っていなければ nil。
  let mark: String?
  /// 詳細の見出しの前回（「前回 今日 16:40　2件をタスク候補に追加」「前回 今日 13:00　失敗」）。失敗の理由は実行履歴だけが出す。
  let last: String

  /// 件数の列を出すか。取得元を持つ並びだけが件数を持つ。
  var counted: Bool { nodes.contains { $0.role == .source } }
}

extension BoardAutomationSummary {
  init(_ automation: Automation, text: AutomationText) {
    let l10n = text.l10n
    let definition = automation.definition
    let output =
      switch definition.sink {
      case .taskCandidates: l10n.string(.boardOutputTaskCandidates)
      }
    let when = text.when(definition.trigger)
    let stepCount = definition.steps.count
    self.output = output
    self.when = when
    nodes = Self.nodes(
      definition,
      counts: automation.runs.first.map { Self.counts($0, stepCount: stepCount) } ?? Counts(),
      when: when, output: output, l10n: l10n)

    func result(_ run: AutomationRun, heading: Bool) -> String {
      if let failure = run.failure {
        return heading
          ? l10n.string(.boardRunFailedShort) : l10n.format(.boardRunFailed, failure)
      }
      let proposed = Self.proposed(run)
      if proposed > 0 {
        return heading
          ? l10n.format(.boardRunAddedTo, proposed, output) : l10n.format(.boardRunAdded, proposed)
      }
      if run.fresh == 0 { return l10n.string(.boardRunNothingNew) }
      if let step = Self.counts(run, stepCount: stepCount).steps.firstIndex(of: 0) {
        return l10n.format(.boardRunAllDropped, step + 1)
      }
      return l10n.string(.boardRunNoneAdded)
    }

    runs = automation.runs.map { run in
      let now = run.trigger == .now ? " " + l10n.string(.automationNowMark) : ""
      return BoardRunLine(
        at: text.stamp(run.startedAt) + now, result: result(run, heading: false),
        tone: Self.tone(run))
    }
    strip = automation.runs.reversed().map(Self.tone)
    if let latest = automation.runs.first {
      let at = text.stamp(latest.startedAt)
      if latest.failure != nil {
        mark = l10n.format(.boardRunMark, at, l10n.string(.boardRunFailedShort))
      } else if Self.proposed(latest) > 0 {
        mark = l10n.format(.boardRunMarkAdded, at, Self.proposed(latest))
      } else {
        mark = l10n.format(.boardRunMark, at, result(latest, heading: false))
      }
      last = l10n.format(
        .boardAutomationLast, text.moment(latest.startedAt), result(latest, heading: true))
    } else {
      mark = nil
      last = l10n.string(.automationNeverRan)
    }
  }

  /// 段の並び。件数は最新の回のもの。モデルは省略なら解いた既定を出す。
  private static func nodes(
    _ definition: AutomationDefinition, counts: Counts, when: String, output: String,
    l10n: LocalizationStore
  ) -> [BoardFlowNode] {
    func command(_ node: inout BoardFlowNode, _ command: BackgroundCommand) {
      node.means = .command(l10n.string(.automationCommand))
      node.source = command.script
      node.note = command.directory.map { l10n.string(.automationDirectory) + "  " + $0 }
    }

    var nodes = [BoardFlowNode(role: .trigger, title: when)]
    if let source = definition.source {
      var node = BoardFlowNode(role: .source, count: counts.source)
      switch source.method {
      case .agent(let agent):
        node.means = .model(AutomationDefinition.model(agent.model, finalStep: false))
        node.source = agent.request
        node.tools = agent.tools
      case .command(let script): command(&node, script)
      }
      nodes.append(node)
      nodes.append(
        BoardFlowNode(role: .orbe, title: l10n.string(.boardOrbeSeen), count: counts.orbe))
    }
    for (index, step) in definition.steps.enumerated() {
      var node = BoardFlowNode(
        role: .step(index + 1), title: step.name,
        count: counts.steps.indices.contains(index) ? counts.steps[index] : nil)
      switch step.method {
      case .agent(let agent):
        node.means = .model(definition.model(of: agent, at: index))
        node.source = agent.instruction
      case .command(let script): command(&node, script)
      }
      nodes.append(node)
    }
    nodes.append(BoardFlowNode(role: .output, title: output, count: counts.output))
    return nodes
  }

  // MARK: - 文言に依らない分類

  /// 回の区分。並べ替え（文言を解かずに走る）も、この分類だけを使う。
  static func tone(_ run: AutomationRun) -> BoardRunTone {
    if run.failure != nil { return .failed }
    return proposed(run) > 0 ? .produced : .quiet
  }

  /// 出力先へ出した数。
  private static func proposed(_ run: AutomationRun) -> Int {
    switch run.sink {
    case .taskCandidates(let report): report.proposed
    case nil: 0
    }
  }

  /// 1 回で各段を出た件数。
  struct Counts: Equatable {
    var source: Int?
    var orbe: Int?
    /// 処理の段の順。届かなかった段から先は無い。
    var steps: [Int] = []
    var output: Int?
  }

  /// 回の記録の段ごとの件数を、届いた段まで並べる。取得元と既に見たものを除くは、取得元を通った回（新しい項目の数を持つ回）
  /// だけが持つ。失敗した回は、記録の最後の段が落ちた段なので、その手前まで。出力先は、成功して最後の段（`stepCount` 番目）まで
  /// 回った回だけが持つ——途中の段が 0 件を出した回・新しい項目が無かった回は、出力先へ届いていない。
  static func counts(_ run: AutomationRun, stepCount: Int) -> Counts {
    var counts = Counts()
    if let fresh = run.fresh {
      counts.source = run.source?.count
      counts.orbe = fresh
    }
    counts.steps = run.steps.map(\.count)
    if run.failure != nil {
      if !counts.steps.isEmpty { counts.steps.removeLast() }
    } else if run.steps.count == stepCount {
      counts.output = proposed(run)
    }
    return counts
  }
}
