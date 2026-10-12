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
/// 今の定義（取得 → 判定）は「トリガー → 取得元 → 既に見たものを除く → 処理 1 判定 → 出力先 タスク候補」の段の並びにする。
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
    let output = l10n.string(.boardOutputTaskCandidates)
    let when = text.when(definition.when)
    self.output = output
    self.when = when
    nodes = Self.nodes(
      definition, counts: automation.runs.first.map(Self.counts) ?? Counts(), when: when,
      output: output, l10n: l10n)

    func result(_ run: AutomationRun, heading: Bool) -> String {
      let counts = Self.counts(run)
      if let failure = run.failure {
        return heading
          ? l10n.string(.boardRunFailedShort) : l10n.format(.boardRunFailed, failure)
      }
      if let proposed = counts.output, proposed > 0 {
        return heading
          ? l10n.format(.boardRunAddedTo, proposed, output) : l10n.format(.boardRunAdded, proposed)
      }
      if run.newItems == 0 { return l10n.string(.boardRunNothingNew) }
      if let step = counts.steps.firstIndex(of: 0) {
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
      } else if let proposed = Self.counts(latest).output, proposed > 0 {
        mark = l10n.format(.boardRunMarkAdded, at, proposed)
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

  /// 今の定義の段の並び。件数は最新の回のもの。
  private static func nodes(
    _ definition: AutomationDefinition, counts: Counts, when: String, output: String,
    l10n: LocalizationStore
  ) -> [BoardFlowNode] {
    var source = BoardFlowNode(role: .source, count: counts.source)
    switch definition.fetch.method {
    case .agent(let agent):
      source.means = .model(agent.model)
      source.source = agent.request
      source.tools = agent.tools
    case .command(let command):
      source.means = .command(l10n.string(.automationCommandFetch))
      source.source = command.script
      source.note = command.directory.map { l10n.string(.automationDirectory) + "  " + $0 }
    }
    return [
      BoardFlowNode(role: .trigger, title: when),
      source,
      BoardFlowNode(role: .orbe, title: l10n.string(.boardOrbeSeen), count: counts.orbe),
      BoardFlowNode(
        role: .step(1), title: l10n.string(.automationJudge),
        means: .model(definition.judge.model), source: definition.judge.instruction,
        count: counts.steps.first),
      BoardFlowNode(role: .output, title: output, count: counts.output),
    ]
  }

  // MARK: - 文言に依らない分類

  /// 回の区分。並べ替え（文言を解かずに走る）も、この分類だけを使う。
  static func tone(_ run: AutomationRun) -> BoardRunTone {
    if run.failure != nil { return .failed }
    return (counts(run).output ?? 0) > 0 ? .produced : .quiet
  }

  /// 1 回で各段を出た件数。
  struct Counts: Equatable {
    var source: Int?
    var orbe: Int?
    /// 処理の段の順。
    var steps: [Int] = []
    var output: Int?
  }

  /// 失敗した回は届いた段までを数える。判定の記録が無い失敗は取得で落ちた回なので何も数えず、判定の記録がある失敗は既に見た
  /// ものを除くまで。判定を起こさなかった回は、処理と出力先へ届いていない。処理 1 を出た数は、提案と対応済みの和。
  static func counts(_ run: AutomationRun) -> Counts {
    if run.failure != nil {
      guard run.judge != nil else { return Counts() }
      return Counts(source: run.fetch.items, orbe: run.newItems)
    }
    guard let judge = run.judge else { return Counts(source: run.fetch.items, orbe: run.newItems) }
    return Counts(
      source: run.fetch.items, orbe: run.newItems, steps: [judge.proposed + judge.resolved],
      output: judge.proposed)
  }
}
