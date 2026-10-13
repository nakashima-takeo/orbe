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
  var verbatim: String?
  var tools: [String] = []
  /// 注記。出どころごとに 1 行。
  var notes: [String] = []
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
  /// 結果を全文で折り返すか（失敗の理由と報告）。ボードでそれを読めるのはこの行だけ。
  let wraps: Bool
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

  /// 実行履歴の最新の行の 1 行目（知らせの本文）。まだ回っていなければ nil。
  var latestLine: String? {
    runs.first.map { String($0.result.prefix { !$0.isNewline }) }
  }
}

extension BoardAutomationSummary {
  init(_ automation: Automation, text: AutomationText) {
    let l10n = text.l10n
    let definition = automation.definition
    let when = text.when(definition.trigger)
    let counts = automation.runs.first.map { Self.counts($0, of: definition) } ?? Counts()
    let sink = Self.sink(automation, count: counts.output, l10n: l10n)
    let output = sink.title
    self.output = output
    self.when = when
    nodes = Self.nodes(definition, counts: counts, when: when, l10n: l10n) + [sink]

    func result(_ run: AutomationRun, heading: Bool) -> String {
      if let failure = run.failure {
        return heading
          ? l10n.string(.boardRunFailedShort) : l10n.format(.boardRunFailed, failure)
      }
      switch run.sink {
      case .command: return l10n.string(.boardRunDone)
      case .taskCandidates(let report) where report.proposed > 0:
        return heading
          ? l10n.format(.boardRunAddedTo, report.proposed, output)
          : l10n.format(.boardRunAdded, report.proposed)
      case .report(let text?): return heading ? String(text.prefix { !$0.isNewline }) : text
      case .report(nil): return l10n.string(.boardRunNothingToReport)
      case .taskCandidates, nil: break
      }
      if run.fresh == 0 { return l10n.string(.boardRunNothingNew) }
      if let step = run.steps.firstIndex(where: { $0.count == 0 }) {
        return l10n.format(.boardRunAllDropped, step + 1)
      }
      return l10n.string(.boardRunNoneAdded)
    }

    runs = automation.runs.map { run in
      let now = run.trigger == .now ? " " + l10n.string(.automationNowMark) : ""
      return BoardRunLine(
        at: text.stamp(run.startedAt) + now, result: result(run, heading: false),
        tone: Self.tone(run), wraps: run.failure != nil || Self.reported(run))
    }
    strip = automation.runs.reversed().map(Self.tone)
    if let latest = automation.runs.first {
      let at = text.stamp(latest.startedAt)
      if latest.failure != nil {
        mark = l10n.format(.boardRunMark, at, l10n.string(.boardRunFailedShort))
      } else if case .taskCandidates(let report) = latest.sink, report.proposed > 0 {
        mark = l10n.format(.boardRunMarkAdded, at, report.proposed)
      } else if Self.reported(latest) {
        mark = l10n.format(.boardRunMarkReported, at)
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

  /// 出力先の段。タイトルは出力先の種類の名前。タスク候補は採用・見送りの累計を注記に、コマンドは全文と作業ディレクトリを
  /// 出し（手段の札は題と同じ語になるので出さない）、報告は定義に何も持たないので題だけ。通知の設定は、どの出力先でも注記の
  /// いちばん下に出す。
  private static func sink(_ automation: Automation, count: Int?, l10n: LocalizationStore)
    -> BoardFlowNode
  {
    var node = BoardFlowNode(role: .output, count: count)
    switch automation.definition.sink {
    case .taskCandidates:
      node.title = l10n.string(.boardOutputTaskCandidates)
      if case .taskCandidates(let state) = automation.sinkState {
        node.notes.append(l10n.format(.boardOutputTally, state.accepted, state.dismissed))
      }
    case .command(let sink):
      node.title = l10n.string(.boardOutputCommand)
      script(&node, sink.command, l10n: l10n)
    case .report:
      node.title = l10n.string(.boardOutputReport)
    }
    switch automation.definition.notify {
    case .menuBar: node.notes.append(l10n.string(.boardOutputNotifyMenuBar))
    case .notificationCenter: node.notes.append(l10n.string(.boardOutputNotifyNotificationCenter))
    case nil: break
    }
    return node
  }

  /// コマンドの段: 手段の札・コマンドの全文・作業ディレクトリ。
  private static func command(
    _ node: inout BoardFlowNode, _ command: BackgroundCommand, l10n: LocalizationStore
  ) {
    node.means = .command(l10n.string(.automationCommand))
    script(&node, command, l10n: l10n)
  }

  /// コマンドの全文と作業ディレクトリ。
  private static func script(
    _ node: inout BoardFlowNode, _ command: BackgroundCommand, l10n: LocalizationStore
  ) {
    node.verbatim = command.script
    if let directory = command.directory {
      node.notes.append(l10n.string(.automationDirectory) + "  " + directory)
    }
  }

  /// 出力先の手前までの段の並び。件数は最新の回のもの。モデルは省略なら解いた既定を出す。
  private static func nodes(
    _ definition: AutomationDefinition, counts: Counts, when: String, l10n: LocalizationStore
  ) -> [BoardFlowNode] {
    var nodes = [BoardFlowNode(role: .trigger, title: when)]
    if let source = definition.source {
      var node = BoardFlowNode(role: .source, count: counts.source)
      switch source.method {
      case .agent(let agent):
        node.means = .model(AutomationDefinition.model(agent.model, finalStep: false))
        node.verbatim = agent.request
        node.tools = agent.tools
      case .command(let script): command(&node, script, l10n: l10n)
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
        node.verbatim = agent.instruction
      case .command(let script): command(&node, script, l10n: l10n)
      }
      nodes.append(node)
    }
    return nodes
  }

  // MARK: - 文言に依らない分類

  /// 回の区分。並べ替え（文言を解かずに走る）も、この分類だけを使う。
  static func tone(_ run: AutomationRun) -> BoardRunTone {
    if run.failure != nil { return .failed }
    return delivered(run).produced ? .produced : .quiet
  }

  /// 報告のある回か。
  private static func reported(_ run: AutomationRun) -> Bool {
    if case .report(.some) = run.sink { true } else { false }
  }

  /// 出力先へ出したかと、出力先の件数。タスク候補は候補を 1 つ以上受けた回、コマンドは走った回、報告は報告のある回が出した回
  /// で、件数は受けた候補の数・渡した行の数・報告の数（1 か 0）。
  private static func delivered(_ run: AutomationRun) -> (produced: Bool, count: Int) {
    switch run.sink {
    case .taskCandidates(let report): (report.proposed > 0, report.proposed)
    case .command(let report): (true, report.count)
    case .report(let text): (text != nil, text == nil ? 0 : 1)
    case nil: (false, 0)
    }
  }

  /// 出力先の記録が、定義の出力先と同じ種類か。
  private static func same(_ report: AutomationSinkReport, _ sink: AutomationSink) -> Bool {
    switch (report, sink) {
    case (.taskCandidates, .taskCandidates), (.command, .command), (.report, .report): true
    case (.taskCandidates, _), (.command, _), (.report, _): false
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
  /// だけが持つ。段で落ちた回（出力先の記録を持たない失敗）は、記録の最後の段が落ちた段なので、その手前まで。出力先は、成功して
  /// 出力先が最後の出力を読んだ回だけが持つ——途中の段が 0 件を出した回・新しい項目が無かった回は、出力先へ届いていない。
  ///
  /// 書き換えても回の記録は残るので、記録が今の定義の段で走ったものかを照合し、合わない段には数を出さない——位置だけで当てると、
  /// 走っていない段や別の出力先に前回の数が付くため。段名は先頭から照合し、最初に食い違った段から先は出さない（前回その先の段が
  /// 受けた入力は、今の並びで受けるものと違う）。最後の段の数は出力先が数えた数（報告なら報告の有無の 1・0）なので、記録で
  /// 出力先が数えた段と今の最後の段が同じ段で、出力先の種類も同じときだけ出す。出力先は、段の並びがすべて合い、種類も同じときだけ。
  private static func counts(_ run: AutomationRun, of definition: AutomationDefinition) -> Counts {
    var counts = Counts()
    if let fresh = run.fresh {
      counts.source = run.source?.count
      counts.orbe = fresh
    }
    let named = zip(run.steps, definition.steps).prefix { $0.name == $1.name }.count
    let sameSink = run.sink.map { same($0, definition.sink) } ?? true
    var steps = run.steps.map(\.count)
    if run.failure != nil, run.sink == nil, !steps.isEmpty { steps.removeLast() }
    steps = Array(steps.prefix(named))
    if let index = steps.indices.last {
      let countedBySink = run.lastStepCountedBySink && index == run.steps.count - 1
      let lastNow = index == definition.steps.count - 1
      if countedBySink != lastNow || (countedBySink && !sameSink) { steps.removeLast() }
    }
    counts.steps = steps
    let reached = run.steps.isEmpty ? run.fresh != 0 : run.lastStepCountedBySink
    if run.failure == nil, reached, named == run.steps.count,
      run.steps.count == definition.steps.count, sameSink
    {
      counts.output = delivered(run).count
    }
    return counts
  }
}
