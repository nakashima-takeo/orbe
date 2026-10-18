import Foundation

/// 回の区分。文言に依らず、回の記録だけから決まる。
enum BoardRunTone: Equatable {
  /// Orbe へ何かを渡した（候補を出した・報告を書いた・外部操作が走った・作業が何かした）。
  case produced
  /// 何も出さなかった。
  case quiet
  case failed
}

/// 回の結果の文の見え方。区分（`BoardRunTone`）と別に持つのは、Orbe へ渡さない回（処理の「1 件を次へ」）も、何かが起きた回は
/// 沈めずに読ませるため。
enum BoardRunShade: Equatable {
  case plain
  /// 何も起きなかった（新着なし・候補なし・報告なし・何もしなかった）。
  case sunk
  case failed
}

/// 成否の印。
enum BoardRunMark: Equatable {
  case success
  case failure
}

/// 一覧の行の値（前回の成否と時刻・次回）。定義と回の記録の形に依るのは、これと詳細の値（`BoardAutomationDetailValue`）・
/// カードの値（`BoardAutomationPartValue`）と、ここに置く共有の読み替え（回の区分・結果の文・畳み）だけで、ボードのビューは
/// これらの値と立ち位置だけを読む——定義の形が変わったとき、直す場所を読み替えに限るため。
struct BoardAutomationSummary: Equatable {
  /// 前回の結果の印。最後の回が失敗した部品があれば失敗。まだ動いていなければ nil。
  let mark: BoardRunMark?
  /// 「前回 16:41」「前回 昨日 23:00」。まだ動いていなければ「まだ動いていない」。時刻はどの部品かを問わず最後に動いた時刻。
  let last: String
  /// 「次回 16:50」。予定のある部品が無ければ「手動」、止めていれば nil。
  let next: String?
}

extension BoardAutomationSummary {
  /// `next` は次に予定で回る時刻。
  init(_ automation: Automation, text: AutomationText, next: Date?) {
    let l10n = text.l10n
    if let latest = automation.runs.first?.run {
      mark = automation.failedParts.isEmpty ? .success : .failure
      last = l10n.format(.boardListLast, text.recent(latest.startedAt))
    } else {
      mark = nil
      last = l10n.string(.boardListNeverRan)
    }
    if automation.paused {
      self.next = nil
    } else if let next {
      self.next = l10n.format(.automationNext, text.recent(next))
    } else {
      self.next =
        automation.graph.nodes.contains {
          if case .scheduled = $0.part.trigger { true } else { false }
        } ? nil : l10n.string(.automationManual)
    }
  }
}

// MARK: - 共有の読み替え（一覧の行・詳細・カード・知らせ）

/// カードの「この部品の実行履歴」の 1 行。
enum BoardRunLine: Equatable {
  case run(BoardRunEntry)
  /// 取得の新着なしが続いた区間を畳んだ 1 行（「13:05〜16:30 は新着なし」）。
  case fold(String)
}

struct BoardRunEntry: Equatable {
  /// 「16:40」「10/3 9:00 手動」。
  let at: String
  let result: String
  let shade: BoardRunShade
  /// 全文を折り返すか（失敗の理由・何もしなかった理由）。
  let wraps: Bool
}

extension BoardAutomationSummary {
  /// 回の区分。並べ替え（文言を解かずに走る）・帯・知らせも、この分類だけを使う。出し直しで通った回は、通った出力で決める。
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

  /// 地図の前回の列の量（「新着 2 件」「1 件を次へ」「候補 2 件」）。報告・作業・外部操作は量を言わない（nil）。
  static func amount(_ run: AutomationPartRun, node: AutomationGraph.Node, text: AutomationText)
    -> (text: String, shade: BoardRunShade)?
  {
    let l10n = text.l10n
    if run.failed { return (l10n.string(.boardMapFailed), .failed) }
    switch run.result {
    case .fetch(let fresh):
      if node.role == .fetch(.everything) {
        return (
          l10n.plural(run.execution.count, one: .boardMapCountOne, other: .boardMapCountOther),
          .plain
        )
      }
      return fresh == 0
        ? (l10n.string(.boardRunNothingNew), .sunk) : (l10n.format(.boardMapFresh, fresh), .plain)
    case .process:
      let passed = run.execution.count
      return (l10n.format(.boardMapPassed, passed), passed > 0 ? .plain : .sunk)
    case .judge(let proposed, _, _):
      return proposed > 0
        ? (l10n.format(.boardMapProposed, proposed), .plain)
        : (l10n.string(.boardMapNoProposals), .sunk)
    case .report, .work, .sideEffect, nil:
      return nil
    }
  }

  /// カードの実行履歴の結果の文。捨てた数・判定の確定で捨てた案・出し直して通ったことを末尾に添える。
  static func result(_ run: AutomationPartRun, node: AutomationGraph.Node, text: AutomationText)
    -> (text: String, shade: BoardRunShade)
  {
    let l10n = text.l10n
    if let failure = text.failure(run, node: node) {
      return (l10n.format(.automationFailedWith, failure), .failed)
    }
    let taken = run.taken ?? 0
    let (body, shade): (String, BoardRunShade)
    switch run.result {
    case .fetch(let fresh):
      if node.role == .fetch(.everything) {
        (body, shade) = (
          l10n.plural(run.execution.count, one: .boardRunCountOne, other: .boardRunCountOther),
          .plain
        )
      } else if fresh == 0 {
        (body, shade) = (l10n.string(.boardRunNothingNew), .sunk)
      } else {
        (body, shade) = (l10n.format(.boardRunFresh, fresh), .plain)
      }
    case .process:
      let passed = run.execution.count
      (body, shade) = (l10n.format(.boardRunPassed, taken, passed), passed > 0 ? .plain : .sunk)
    case .judge(let proposed, _, _):
      (body, shade) =
        proposed > 0
        ? (
          l10n.format(taken == 1 ? .boardRunJudgedOne : .boardRunJudgedOther, taken, proposed),
          .plain
        )
        : (l10n.plural(taken, one: .boardRunJudgedNoneOne, other: .boardRunJudgedNoneOther), .sunk)
    case .report(.some):
      (body, shade) =
        run.taken.map { (l10n.format(.boardRunSummarized, $0), .plain) }
        ?? (l10n.string(.boardRunReported), .plain)
    case .report(nil):
      (body, shade) = (l10n.string(.boardRunNothingToReport), .sunk)
    case .work(_, let nothing?):
      (body, shade) = (l10n.format(.boardRunNothingDone, nothing), .sunk)
    case .work(_, nil):
      (body, shade) = (l10n.string(.boardRunDone), .plain)
    case .sideEffect, nil:
      (body, shade) = (l10n.string(.boardRunExecuted), .plain)
    }
    var asides: [String] = []
    if run.breach?.redo != nil { asides.append(l10n.string(.boardRunRedonePassed)) }
    if let old = run.dropped.counts[.expired] {
      asides.append(l10n.format(.boardRunDroppedOld, old))
    }
    if let many = run.dropped.counts[.overflow] {
      asides.append(l10n.format(.boardRunDroppedOverflow, many))
    }
    if case .judge(_, _, let dismissed) = run.result { asides += text.dismissals(dismissed) }
    guard !asides.isEmpty else { return (body, shade) }
    return (
      l10n.format(
        .automationWithOriginal, body,
        asides.joined(separator: l10n.string(.boardRunAsideSeparator))),
      shade
    )
  }

  /// 部品の回を新しい順に 1 行ずつ。取得の新着なし（失敗でない取得の回で新しい項目が 0）が `foldLength` 回以上続く区間は、
  /// 期間の 1 行に畳む——短い間隔の取得の「新着なし」が、他の回を押し出さないため。
  static func lines(_ runs: [AutomationPartRun], node: AutomationGraph.Node, text: AutomationText)
    -> [BoardRunLine]
  {
    var lines: [BoardRunLine] = []
    var quiet: [AutomationPartRun] = []
    func flush() {
      if quiet.count >= foldLength, let newest = quiet.first, let oldest = quiet.last {
        lines.append(
          .fold(
            text.l10n.format(
              .boardRunFold, text.stamp(oldest.startedAt),
              span(oldest.startedAt, newest.startedAt, text))))
      } else {
        lines += quiet.map { entry($0, node: node, text: text) }
      }
      quiet = []
    }
    for run in runs {
      if case .fetch(0) = run.result, !run.failed, node.role != .fetch(.everything),
        run.dropped.isEmpty
      {
        quiet.append(run)
      } else {
        flush()
        lines.append(entry(run, node: node, text: text))
      }
    }
    flush()
    return lines
  }

  /// 区間の終わりの時刻。始まりと同じ日なら時刻だけ（「13:05〜16:30」）。
  private static func span(_ from: Date, _ to: Date, _ text: AutomationText) -> String {
    TaskItem.DueDate(from, timeZone: text.timeZone) == TaskItem.DueDate(to, timeZone: text.timeZone)
      ? text.clock(to) : text.stamp(to)
  }

  private static func entry(
    _ run: AutomationPartRun, node: AutomationGraph.Node, text: AutomationText
  )
    -> BoardRunLine
  {
    let at = text.stamp(run.startedAt)
    let result = result(run, node: node, text: text)
    var wraps = run.failed
    if case .work(_, .some) = run.result { wraps = true }
    return .run(
      BoardRunEntry(
        at: run.trigger == .now ? text.l10n.format(.boardRunManual, at) : at,
        result: result.text, shade: result.shade, wraps: wraps))
  }

  /// 畳む区間の最短の長さ。
  static let foldLength = 3

  /// 部品の回 1 つを知らせの本文にした 1 行（「連絡: 5 件を判定して候補 1 件」）。報告と作業の応答は文の 1 行目。部品は名前
  /// だけで言う。
  static func line(
    _ run: AutomationPartRun, part key: String, in automation: Automation, text: AutomationText
  ) -> String {
    guard let node = automation.graph.node(key) else { return key }
    let body: String =
      switch run.result {
      case .report(let report?) where !run.failed: report
      case .work(let reply?, nil) where !run.failed: reply
      default: result(run, node: node, text: text).text
      }
    return String((node.part.name + ": " + body).prefix { !$0.isNewline })
  }
}
