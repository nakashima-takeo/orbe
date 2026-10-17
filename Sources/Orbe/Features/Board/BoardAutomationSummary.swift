import Foundation

/// 流れの部品 1 行。文言まで解いた描画用の値。
struct BoardPartLine: Equatable {
  let key: String
  /// 役割の名前（「取得」「判定」）。
  let role: String
  let name: String
  /// 予定の札（「30分ごと」「手動」「届いたら」）。
  let schedule: String
  /// 入力の部品の名前（「A・B」）。入力の無い部品は nil。
  let inputs: String?
  /// 溜まりの件数。入力のある部品だけ。
  let inbox: Int?
  /// 前回の回で読めた数。まだ回っていなければ nil。
  let count: Int?
}

/// 回の区分。文言に依らず、回の記録だけから決まる。
enum BoardRunTone: Equatable {
  /// Orbe へ何かを渡した（候補を出した・報告を書いた・副作用が走った・仕事が何かした）。
  case produced
  /// 何も出さなかった。
  case quiet
  case failed
}

/// 実行履歴の 1 行。
struct BoardRunLine: Equatable {
  /// 「16:40」「10/3 9:00 今すぐ」。
  let at: String
  /// 頭に部品の名前を付けた結果。
  let result: String
  let tone: BoardRunTone
  /// 結果を全文で折り返すか（失敗の理由・報告・agent の応答）。ボードでそれを読めるのはこの行だけ。
  let wraps: Bool
}

/// 自動化 1 つをボードの描画用の値へ読み替えたもの。定義と回の記録の形に依るのはこのファイルだけで、ボードのビューはこの値と
/// 立ち位置だけを読む——定義の形が変わったとき、直すのがここだけで済むため。
///
/// 流れは部品を入力の深さ順（同じ深さは定義の順）に 1 行ずつ並べる。実行履歴は部品の回を新しい順に混ぜる。
struct BoardAutomationSummary: Equatable {
  /// Orbe へ渡す先の種類の名前（一覧の 2 行目。「タスク候補・報告」、Orbe へ渡す部品が無ければ「コマンド」）。
  let output: String
  /// 予定（一覧の 2 行目。予定のある部品が 1 つならその言葉、複数なら次に来る部品の予定と「ほか N」、無ければ「手動」）。
  let when: String
  let parts: [BoardPartLine]
  /// 流れの下の注記（採用・見送りの累計・通知の設定）。
  let notes: [String]
  /// 新しい順。
  let runs: [BoardRunLine]
  /// 帯（直近の `stripLength` 回）。古い回が左。
  let strip: [BoardRunTone]
  /// 一覧の右端の、最新の回の文（「16:40 に 2件を追加」「13:00 に失敗」）。まだ回っていなければ nil。
  let mark: String?
  /// 詳細の見出しの前回（「前回 今日 16:40　判定: 2件をタスク候補に追加」）。失敗の理由は実行履歴だけが出す。
  let last: String

  /// 帯に並べる回の数。
  static let stripLength = 20

  /// 実行履歴の最新の行の 1 行目。まだ回っていなければ nil。
  var latestLine: String? {
    runs.first.map { String($0.result.prefix { !$0.isNewline }) }
  }
}

extension BoardAutomationSummary {
  /// `next` は次に予定で回る部品の鍵（予定のある部品が複数のときの「いつ」に使う）。
  init(_ automation: Automation, text: AutomationText, next: String?) {
    let l10n = text.l10n
    let graph = automation.graph
    let destinations = Self.destinations(graph, l10n: l10n)
    output = destinations
    when = Self.when(graph, next: next, text: text)
    parts = graph.byDepth.map { node in
      let state = automation.state(node.key)
      return BoardPartLine(
        key: node.key, role: text.role(node.role), name: node.part.name,
        schedule: text.schedule(node.part.trigger),
        inputs: node.part.inputs.isEmpty
          ? nil
          : node.part.inputs.map { graph.node($0)?.part.name ?? $0 }.joined(
            separator: l10n.string(.automationListSeparator)),
        inbox: node.part.inputs.isEmpty ? nil : state.inbox,
        count: state.runs.first.map(\.execution.count))
    }
    var notes: [String] = []
    if automation.judges {
      notes.append(
        l10n.format(.boardOutputTally, automation.tally.accepted, automation.tally.dismissed))
    }
    if let notify = automation.notify {
      notes.append(l10n.format(.boardOutputNotify, l10n.string(notify.labelKey)))
    }
    self.notes = notes
    let keyed = automation.runs
    let names = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.key, $0.part.name) })
    runs = keyed.map { entry in
      let now = entry.run.trigger == .now ? " " + l10n.string(.automationNowMark) : ""
      return BoardRunLine(
        at: text.stamp(entry.run.startedAt) + now,
        result: (names[entry.part] ?? entry.part) + ": "
          + Self.result(entry.run, heading: false, output: destinations, text: text),
        tone: Self.tone(entry.run), wraps: Self.wraps(entry.run))
    }
    strip = keyed.prefix(Self.stripLength).reversed().map { Self.tone($0.run) }
    guard let latest = keyed.first else {
      mark = nil
      last = l10n.string(.automationNeverRan)
      return
    }
    let at = text.stamp(latest.run.startedAt)
    let heading = Self.result(latest.run, heading: true, output: destinations, text: text)
    switch latest.run.result {
    case _ where latest.run.failed:
      mark = l10n.format(.boardRunMark, at, l10n.string(.boardRunFailedShort))
    case .judge(let proposed, _, _) where proposed > 0:
      mark = l10n.format(.boardRunMarkAdded, at, proposed)
    case .report(.some):
      mark = l10n.format(.boardRunMarkReported, at)
    default:
      mark = l10n.format(.boardRunMark, at, heading)
    }
    last = l10n.format(
      .boardAutomationLast, text.moment(latest.run.startedAt),
      (names[latest.part] ?? latest.part) + ": " + heading)
  }

  /// 部品の回 1 つを知らせの本文にした 1 行（「判定: 2件を追加」）。実行履歴の行の 1 行目と同じ文。
  static func line(
    _ run: AutomationPartRun, part key: String, in automation: Automation, text: AutomationText
  ) -> String {
    let name = automation.graph.node(key)?.part.name ?? key
    let output = destinations(automation.graph, l10n: text.l10n)
    let result = result(run, heading: false, output: output, text: text)
    return String((name + ": " + result).prefix { !$0.isNewline })
  }

  /// Orbe へ渡す先の種類（定義の順に重ねず並べる）。どれも無ければ「コマンド」。
  private static func destinations(_ graph: AutomationGraph, l10n: LocalizationStore) -> String {
    var kinds: [String] = []
    for node in graph.nodes {
      let kind: L10nKey
      switch node.part.destination {
      case .taskCandidates: kind = .boardOutputTaskCandidates
      case .report: kind = .boardOutputReport
      case .nextPart, .sideEffect: continue
      }
      let name = l10n.string(kind)
      if !kinds.contains(name) { kinds.append(name) }
    }
    return kinds.isEmpty
      ? l10n.string(.boardOutputCommand)
      : kinds.joined(separator: l10n.string(.automationListSeparator))
  }

  private static func when(_ graph: AutomationGraph, next: String?, text: AutomationText) -> String
  {
    let scheduled = graph.nodes.filter {
      if case .scheduled = $0.part.trigger { true } else { false }
    }
    guard let first = scheduled.first else { return text.l10n.string(.automationManual) }
    let shown = scheduled.first { $0.key == next } ?? first
    let words = text.schedule(shown.part.trigger)
    return scheduled.count == 1
      ? words : text.l10n.format(.automationOthers, words, scheduled.count - 1)
  }

  /// 回の結果。見出し（一覧の右端・詳細の前回・知らせ）は 1 行に縮め、実行履歴は全文を出す。
  private static func result(
    _ run: AutomationPartRun, heading: Bool, output: String, text: AutomationText
  ) -> String {
    let l10n = text.l10n
    if let failure = run.failure {
      return heading ? l10n.string(.boardRunFailedShort) : l10n.format(.boardRunFailed, failure)
    }
    switch run.result {
    case .fetch(let fresh) where fresh == 0:
      return l10n.string(.boardRunNothingNew)
    case .judge(let proposed, _, _) where proposed > 0:
      return heading
        ? l10n.format(.boardRunAddedTo, proposed, output) : l10n.format(.boardRunAdded, proposed)
    case .judge:
      return l10n.string(.boardRunNoneAdded)
    case .report(let body?), .work(let body?, _):
      return heading ? String(body.prefix { !$0.isNewline }) : body
    case .work(nil, let nothing?):
      return heading
        ? l10n.string(.boardRunNothingDone) : l10n.format(.boardRunNothingDoneBecause, nothing)
    default:
      return text.outcome(run)
    }
  }

  // MARK: - 文言に依らない分類

  /// 回の区分。並べ替え（文言を解かずに走る）と知らせも、この分類だけを使う。出し直しで通った回は、通った出力で決める。
  static func tone(_ run: AutomationPartRun) -> BoardRunTone {
    if run.failed { return .failed }
    switch run.result {
    case .judge(let proposed, _, _): return proposed > 0 ? .produced : .quiet
    case .report(let text): return text != nil ? .produced : .quiet
    case .work(_, let nothing): return nothing == nil ? .produced : .quiet
    case .sideEffect: return .produced
    case .fetch, .process, nil: return .quiet
    }
  }

  private static func wraps(_ run: AutomationPartRun) -> Bool {
    switch run.result {
    case _ where run.failed: true
    case .report(.some), .work(.some, _), .work(nil, .some): true
    default: false
    }
  }
}
