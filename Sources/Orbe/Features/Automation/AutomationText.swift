import Foundation

/// 自動追加を人に見せる文（時刻・回の要約・いつ・取得元と処理の段の行の並び）。何をどの順に、どこを原文として出すかまでを決め、
/// 描き方（字の大きさ・箱）は使う画面が決める。暦日は渡された今日とタイムゾーンで決める。
struct AutomationText {
  let l10n: LocalizationStore
  let today: TaskItem.DueDate
  let timeZone: TimeZone

  /// 取得元・段の 1 行。原文（依頼文・コマンド・指示文）は実行されるとおりの文字。どれも切らずに全文を出す——承認なしで
  /// 裏で走るもの（使えるツール・作業ディレクトリ・コマンド）を、画面でいつも確かめられるため。
  enum Line: Equatable {
    case plain(String)
    case source(String)
  }

  /// 「9:12」。
  private func clock(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.hour, .minute], from: date)
    return Self.clock(hour: c.hour ?? 0, minute: c.minute ?? 0)
  }

  /// 今日なら「13:00」、ほかの日は「10/3 13:00」。
  private func stamp(_ date: Date) -> String {
    TaskDueText.stamp(date, timeZone, today: today)
  }

  /// 今日なら「今日 10:24」、ほかの日は「10/9 10:24」。
  func moment(_ date: Date) -> String {
    let day = TaskItem.DueDate(date, timeZone: timeZone)
    return day == today ? "\(l10n.string(.automationToday)) \(clock(date))" : stamp(date)
  }

  /// 行の右の時刻。今日なら「10:24」、ほかの日は「10/9」。
  func short(_ date: Date) -> String {
    let day = TaskItem.DueDate(date, timeZone: timeZone)
    return day == today ? clock(date) : TaskDueText.date(day, today: today)
  }

  /// 候補の一覧の頭。「13:00 の回 · 9 件取得 → 新しい 4 件を処理 → 候補 2」。
  func runHeadline(_ run: AutomationRun?) -> String {
    guard let run else { return l10n.string(.automationNeverRan) }
    return l10n.format(.automationRunAt, stamp(run.startedAt)) + " · "
      + summary(
        run, proposedOne: .automationProposedShortOne, proposedOther: .automationProposedShortOther)
  }

  /// 自動追加の中身の前回。「今日 9:12 · 14 件取得 → 新しい 3 件を処理 → 候補 1 件」。
  func runDetail(_ run: AutomationRun?) -> String {
    guard let run else { return l10n.string(.automationNeverRan) }
    return moment(run.startedAt) + " · " + longSteps(run)
  }

  /// 回の記録の 1 行。「今すぐ」で回った回は時刻の後に印を添える。「今日 9:12 今すぐ · 14 件取得 → …」。
  func runLine(_ run: AutomationRun) -> String {
    let mark = run.trigger == .now ? " " + l10n.string(.automationNowMark) : ""
    return moment(run.startedAt) + mark + " · " + longSteps(run)
  }

  /// 前回の結果の短い言い方。「13:00 · 失敗」「16:30 · 候補 2 件」「16:00 · 新しい項目なし」。理由は回の記録で読む。
  func outcome(_ run: AutomationRun) -> String {
    let result =
      if run.failure != nil {
        l10n.string(.automationFailedShort)
      } else if (run.fresh ?? 0) == 0 {
        l10n.string(.automationNothingNew)
      } else {
        l10n.plural(
          Self.proposed(run), one: .automationProposedLongOne, other: .automationProposedLongOther)
      }
    return stamp(run.startedAt) + " · " + result
  }

  private func longSteps(_ run: AutomationRun) -> String {
    summary(
      run, proposedOne: .automationProposedLongOne, proposedOther: .automationProposedLongOther)
  }

  private func summary(_ run: AutomationRun, proposedOne: L10nKey, proposedOther: L10nKey) -> String
  {
    if let failure = run.failure { return l10n.format(.automationFailed, failure) }
    var parts = [l10n.format(.automationFetched, run.source?.count ?? 0)]
    let fresh = run.fresh ?? 0
    if fresh == 0 {
      parts.append(l10n.string(.automationNothingNew))
    } else {
      parts.append(l10n.format(.automationProcessed, fresh))
      parts.append(l10n.plural(Self.proposed(run), one: proposedOne, other: proposedOther))
    }
    return parts.joined(separator: " → ")
  }

  private static func proposed(_ run: AutomationRun) -> Int {
    switch run.sink {
    case .taskCandidates(let report): report.proposed
    case nil: 0
    }
  }

  /// 取得元の行の並び: やり方・使えるツール・依頼文かコマンド・作業ディレクトリ・取得の性質。いつは含めない。
  func source(_ source: AutomationSource) -> [Line] {
    var lines: [Line]
    switch source.method {
    case .agent(let agent):
      let model = AutomationDefinition.model(agent.model, finalStep: false)
      lines = [
        .plain([l10n.string(.automationAgentFetch), agent.cli, model].joined(separator: " · ")),
        .plain(l10n.string(.automationTools) + "  " + agent.tools.joined(separator: ", ")),
        .source(agent.request),
      ]
    case .command(let command):
      lines = [.plain(l10n.string(.automationCommand)), .source(command.script)]
      lines += directory(command)
    }
    lines.append(.plain(coverage(source.coverage)))
    return lines
  }

  /// 処理の段の行の並び。agent の段は「名前 · CLI · モデル」と指示文、コマンドの段は「名前 · コマンド」とコマンドと作業
  /// ディレクトリ。
  func steps(_ definition: AutomationDefinition) -> [Line] {
    definition.steps.enumerated().flatMap { index, step -> [Line] in
      switch step.method {
      case .agent(let agent):
        return [
          .plain(
            [step.name, agent.cli, definition.model(of: agent, at: index)].joined(separator: " · ")),
          .source(agent.instruction),
        ]
      case .command(let command):
        return [
          .plain([step.name, l10n.string(.automationCommand)].joined(separator: " · ")),
          .source(command.script),
        ] + directory(command)
      }
    }
  }

  private func directory(_ command: BackgroundCommand) -> [Line] {
    command.directory.map { [.plain(l10n.string(.automationDirectory) + "  " + $0)] } ?? []
  }

  /// 取得の性質と、それで候補がいつ下がるか。
  private func coverage(_ coverage: AutomationCoverage) -> String {
    switch coverage {
    case .currentSet: l10n.string(.automationCurrentSet)
    case .newArrivals: l10n.string(.automationNewArrivals)
    case .everything: l10n.string(.automationEverything)
    }
  }

  /// 「30 分ごと」「毎日 9:00・13:00」。
  func when(_ timing: BackgroundTiming) -> String {
    switch timing {
    case .every(let interval):
      return l10n.format(.automationEvery, Int(interval / 60))
    case .daily(let times):
      let sorted = times.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
      return l10n.format(
        .automationDaily,
        sorted.map { Self.clock(hour: $0.hour, minute: $0.minute) }.joined(separator: "・"))
    }
  }

  /// 「次 17:00」（今日でなければ日付付き）。
  func next(_ date: Date) -> String {
    l10n.format(.automationNext, stamp(date))
  }

  /// 「期限 10/10（金）」。
  func due(_ due: TaskItem.DueDate) -> String {
    l10n.format(
      .automationDue, TaskDueText.date(due, today: today),
      TaskDueText.weekdays(l10n.language)[due.weekday])
  }

  /// リンクのホスト名（出どころの種類は知らないので、ホスト名で言う）。
  static func host(_ link: String) -> String {
    URL(string: link)?.host ?? link
  }

  private static func clock(hour: Int, minute: Int) -> String {
    String(format: "%d:%02d", hour, minute)
  }
}
