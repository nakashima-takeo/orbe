import Foundation

/// 回の区分。文言に依らず、回の記録だけから決まる。
enum BoardRunTone: Equatable {
  /// Orbe へ何かを渡した（候補を出した・報告を書いた・副作用が走った・仕事が何かした）。
  case produced
  /// 何も出さなかった。
  case quiet
  case failed
}

/// 回の結果の文の見え方。区分（`BoardRunTone`）と別に持つのは、Orbe へ渡さない回（処理の「2件 → 2件」）も、何かが起きた回は
/// 沈めずに読ませるため。
enum BoardRunShade: Equatable {
  case plain
  /// 何も起きなかった（新着なし・追加なし・報告なし・何もしなかった）。
  case sunk
  case failed
  /// 走っている（地図の前回だけ）。
  case running
}

/// 実行履歴とカードの「この部品の回」の 1 行。
enum BoardRunLine: Equatable {
  case run(BoardRunEntry)
  /// 取得の新着なしが続いた区間を畳んだ 1 行（「16:30 以前　新着なし ×75」）。
  case fold(String)

  /// 帯の色。畳んだ行は何も出さなかった回の色。
  var tone: BoardRunTone {
    switch self {
    case .run(let entry): entry.tone
    case .fold: .quiet
    }
  }
}

struct BoardRunEntry: Equatable {
  /// 「16:40」「10/3 9:00 今すぐ」。
  let at: String
  /// 部品の名前。カードの回（部品が決まっている）は nil。
  let part: String?
  let result: String
  let shade: BoardRunShade
  let tone: BoardRunTone
  /// 全文を折り返すか（失敗の理由・報告・agent の応答）。カードの回だけが折り返す。
  let wraps: Bool
}

/// 一覧の行の値（Orbe へ渡す先の種類・いつ・右端の文）。定義と回の記録の形に依るのは、これと詳細の値
/// （`BoardAutomationDetailValue`）・カードの値（`BoardAutomationPartValue`）と、ここに置く共有の読み替え（結果の文・回の区分・
/// 畳み）だけで、ボードのビューはこれらの値と立ち位置だけを読む——定義の形が変わったとき、直す場所を読み替えに限るため。
struct BoardAutomationSummary: Equatable {
  /// Orbe へ渡す先の種類の名前（一覧の 2 行目。「タスク候補・報告」、Orbe へ渡す部品が無ければ「コマンド」）。
  let output: String
  /// 予定（一覧の 2 行目。予定のある部品が 1 つならその言葉、複数なら次に来る部品の予定と「ほか N」、無ければ「手動」）。
  let when: String
  /// 一覧の右端の、失敗した部品か最新の回の文（「13:00 判定: 連絡 で失敗」「16:40 に 2件を追加」）。まだ回っていなければ nil。
  let mark: String?
}

extension BoardAutomationSummary {
  /// `next` は次に予定で回る部品の鍵（予定のある部品が複数のときの「いつ」に使う）。
  init(_ automation: Automation, text: AutomationText, next: String?) {
    let l10n = text.l10n
    let graph = automation.graph
    output = Self.destinations(graph, l10n: l10n)
    when = Self.when(graph, next: next, text: text)
    let failed = automation.failedParts
    if let first = failed.first, let at = automation.state(first.key).runs.first?.startedAt,
      let parts = text.failed(failed)
    {
      mark = l10n.format(.boardRunMarkFailed, text.stamp(at), parts)
      return
    }
    guard let latest = automation.runs.first?.run else {
      mark = nil
      return
    }
    let at = text.stamp(latest.startedAt)
    switch latest.result {
    case .judge(let proposed, _, _) where proposed > 0:
      mark = l10n.format(.boardRunMarkAdded, at, proposed)
    case .report(.some):
      mark = l10n.format(.boardRunMarkReported, at)
    case .work(.some, _):
      // 応答の文は長くなりうる。右端は名前を潰さない短い語で言い、文はカードで読む。
      mark = l10n.format(.boardRunMark, at, l10n.string(.boardRunDone))
    default:
      mark = l10n.format(.boardRunMark, at, Self.heading(latest, text: text))
    }
  }

  /// 部品の回 1 つを知らせの本文にした 1 行（「判定: 5件を判定 → 2件を追加」）。実行履歴の行（部品の名前と結果）と同じ文。
  static func line(
    _ run: AutomationPartRun, part key: String, in automation: Automation, text: AutomationText
  ) -> String {
    let name = automation.graph.node(key)?.part.name ?? key
    return String((name + ": " + result(run, text: text).text).prefix { !$0.isNewline })
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
}

// MARK: - 共有の読み替え（一覧の行・詳細・カード・知らせ）

extension BoardAutomationSummary {
  /// 見出しの結果（一覧の右端・詳細の前回）。1 行に縮める。
  static func heading(_ run: AutomationPartRun, text: AutomationText) -> String {
    let l10n = text.l10n
    if run.failed { return l10n.string(.boardRunFailedShort) }
    switch run.result {
    case .fetch(let fresh) where fresh == 0:
      return l10n.string(.boardRunNothingNew)
    case .judge(let proposed, _, _) where proposed > 0:
      return l10n.format(.boardRunAddedTo, proposed, l10n.string(.boardOutputTaskCandidates))
    case .judge:
      return l10n.string(.boardRunNoneAdded)
    case .report(let body?), .work(let body?, _):
      return String(body.prefix { !$0.isNewline })
    case .work(nil, .some):
      return l10n.string(.boardRunNothingDone)
    default:
      return text.outcome(run)
    }
  }

  /// 実行履歴とカードの回の結果の文と見え方。報告・応答・理由は全文。
  static func result(_ run: AutomationPartRun, text: AutomationText) -> (
    text: String, shade: BoardRunShade
  ) {
    let l10n = text.l10n
    if let failure = run.failure { return (l10n.format(.boardRunFailed, failure), .failed) }
    let taken = run.taken ?? 0
    switch run.result {
    case .fetch(let fresh):
      return fresh == 0
        ? (l10n.string(.boardRunNothingNew), .sunk) : (l10n.format(.boardRunFresh, fresh), .plain)
    case .process:
      return (l10n.format(.boardRunTaken, taken, run.execution.count), .plain)
    case .judge(let proposed, _, _):
      return proposed > 0
        ? (l10n.format(.boardRunJudgedAdded, taken, proposed), .plain)
        : (l10n.format(.boardRunJudgedNone, taken), .sunk)
    case .report(let body?), .work(let body?, _):
      return (body, .plain)
    case .report(nil):
      return (l10n.string(.boardRunNothingToReport), .sunk)
    case .work(nil, let nothing?):
      return (l10n.format(.boardRunNothingDoneBecause, nothing), .sunk)
    case .work(nil, nil), .sideEffect, nil:
      return (l10n.string(.boardRunDone), .plain)
    }
  }

  /// 地図の行の前回（「新しい 2 / 18」「1 → 1」「候補 2 / 12」「報告した」）。件数だけを言い、文は実行履歴とカードで読む。
  static func brief(_ run: AutomationPartRun, text: AutomationText) -> (
    text: String, shade: BoardRunShade
  ) {
    let l10n = text.l10n
    if run.failed { return (l10n.string(.boardRunFailedShort), .failed) }
    let taken = run.taken ?? 0
    switch run.result {
    case .fetch(let fresh):
      return fresh == 0
        ? (l10n.string(.boardRunNothingNew), .sunk)
        : (l10n.format(.boardMapFresh, fresh, run.execution.count), .plain)
    case .process:
      return (l10n.format(.boardMapTaken, taken, run.execution.count), .plain)
    case .judge(let proposed, _, _):
      return (l10n.format(.boardMapProposed, proposed, taken), proposed > 0 ? .plain : .sunk)
    case .report(let body):
      return body != nil
        ? (l10n.string(.boardMapReported), .plain) : (l10n.string(.boardRunNothingToReport), .sunk)
    case .work(_, .some):
      return (l10n.string(.boardRunNothingDone), .sunk)
    case .work(_, nil), .sideEffect, nil:
      return (l10n.string(.boardRunDone), .plain)
    }
  }

  /// 回を新しい順に 1 行ずつ。取得の新着なしが `foldLength` 回以上続く区間は 1 行に畳む（時刻は区間の最も新しい回、数は区間の
  /// 回の数）——10 分ごとの取得の「新着なし」が、他の部品の回を実行履歴の外へ押し出さないため。`name` を渡せば行に部品の名前を
  /// 付ける。
  static func lines(
    _ runs: [AutomationKeyedRun], name: ((String) -> String)?, text: AutomationText
  ) -> [BoardRunLine] {
    var lines: [BoardRunLine] = []
    var quiet: [AutomationKeyedRun] = []
    func flush() {
      if quiet.count >= foldLength, let newest = quiet.first {
        lines.append(
          .fold(text.l10n.format(.boardRunFold, text.stamp(newest.run.startedAt), quiet.count)))
      } else {
        lines += quiet.map { entry($0, name: name, text: text) }
      }
      quiet = []
    }
    for keyed in runs {
      if case .fetch(0) = keyed.run.result, !keyed.run.failed {
        quiet.append(keyed)
      } else {
        flush()
        lines.append(entry(keyed, name: name, text: text))
      }
    }
    flush()
    return lines
  }

  private static func entry(
    _ keyed: AutomationKeyedRun, name: ((String) -> String)?, text: AutomationText
  ) -> BoardRunLine {
    let run = keyed.run
    let now = run.trigger == .now ? " " + text.l10n.string(.automationNowMark) : ""
    let result = result(run, text: text)
    return .run(
      BoardRunEntry(
        at: text.stamp(run.startedAt) + now, part: name?(keyed.part), result: result.text,
        shade: result.shade, tone: tone(run), wraps: wraps(run)))
  }

  /// 畳む区間の最短の長さ。
  static let foldLength = 3

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
