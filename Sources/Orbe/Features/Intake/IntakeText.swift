import Foundation

/// 自動追加を人に見せる文（時刻・回の要約・いつ・取得と判定の行の並び）。何をどの順に、どこを原文として出すかまでを決め、
/// 描き方（字の大きさ・箱）は使う画面が決める。暦日は渡された今日とタイムゾーンで決める。
struct IntakeText {
  let l10n: LocalizationStore
  let today: TaskItem.DueDate
  let timeZone: TimeZone

  /// 取得・判定の 1 行。原文（依頼文・コマンド・指示文）は実行されるとおりの文字。どれも切らずに全文を出す——承認なしで
  /// 裏で走るもの（使えるツール・作業ディレクトリ・コマンド）を、画面でいつも確かめられるため。
  enum Line: Equatable {
    case plain(String)
    case source(String)
  }

  /// 「9:12」。
  func clock(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.hour, .minute], from: date)
    return Self.clock(hour: c.hour ?? 0, minute: c.minute ?? 0)
  }

  /// 今日なら「13:00」、ほかの日は「10/3 13:00」。
  func stamp(_ date: Date) -> String {
    TaskDueText.stamp(date, timeZone, today: today)
  }

  /// 今日なら「今日 10:24」、ほかの日は「10/9 10:24」。
  func moment(_ date: Date) -> String {
    let day = TaskItem.DueDate(date, timeZone: timeZone)
    return day == today ? "\(l10n.string(.intakeToday)) \(clock(date))" : stamp(date)
  }

  /// 行の右の時刻。今日なら「10:24」、ほかの日は「10/9」。
  func short(_ date: Date) -> String {
    let day = TaskItem.DueDate(date, timeZone: timeZone)
    return day == today ? clock(date) : TaskDueText.date(day, today: today)
  }

  /// 候補の一覧の頭。「13:00 の回 · 9 件取得 → 新しい 4 件を判定 → 候補 2」。
  func runHeadline(_ run: IntakeRun?) -> String {
    guard let run else { return l10n.string(.intakeNeverRan) }
    return l10n.format(.intakeRunAt, stamp(run.startedAt)) + " · "
      + steps(run, proposedOne: .intakeProposedShortOne, proposedOther: .intakeProposedShortOther)
  }

  /// 自動追加の中身の前回。「今日 9:12 · 14 件取得 → 新しい 3 件を判定 → 候補 1 件」。
  func runDetail(_ run: IntakeRun?) -> String {
    guard let run else { return l10n.string(.intakeNeverRan) }
    return moment(run.startedAt) + " · " + longSteps(run)
  }

  /// 回の記録の 1 行。「今すぐ」で回った回は時刻の後に印を添える。「今日 9:12 今すぐ · 14 件取得 → …」。
  func runLine(_ run: IntakeRun) -> String {
    let mark = run.trigger == .now ? " " + l10n.string(.intakeNowMark) : ""
    return moment(run.startedAt) + mark + " · " + longSteps(run)
  }

  /// 前回の結果の短い言い方。「13:00 · 失敗」「16:30 · 候補 2 件」「16:00 · 新しい項目なし」。理由は回の記録で読む。
  func outcome(_ run: IntakeRun) -> String {
    let result =
      if run.failure != nil {
        l10n.string(.intakeFailedShort)
      } else if run.newItems == 0 {
        l10n.string(.intakeNothingNew)
      } else {
        l10n.plural(
          run.judge?.proposed ?? 0, one: .intakeProposedLongOne, other: .intakeProposedLongOther)
      }
    return stamp(run.startedAt) + " · " + result
  }

  private func longSteps(_ run: IntakeRun) -> String {
    steps(run, proposedOne: .intakeProposedLongOne, proposedOther: .intakeProposedLongOther)
  }

  private func steps(_ run: IntakeRun, proposedOne: L10nKey, proposedOther: L10nKey) -> String {
    if let failure = run.failure { return l10n.format(.intakeFailed, failure) }
    var parts = [l10n.format(.intakeFetched, run.fetch.items)]
    if run.newItems == 0 {
      parts.append(l10n.string(.intakeNothingNew))
    } else {
      parts.append(l10n.format(.intakeJudged, run.newItems))
      parts.append(
        l10n.plural(run.judge?.proposed ?? 0, one: proposedOne, other: proposedOther))
    }
    return parts.joined(separator: " → ")
  }

  /// 取得の行の並び: やり方・使えるツール・依頼文かコマンド・作業ディレクトリ・取得の性質。いつは含めない。
  func fetch(_ fetch: IntakeFetch) -> [Line] {
    var lines: [Line]
    switch fetch.method {
    case .agent(let agent):
      lines = [
        .plain([l10n.string(.intakeAgentFetch), agent.cli, agent.model].joined(separator: " · ")),
        .plain(l10n.string(.intakeTools) + "  " + agent.tools.joined(separator: ", ")),
        .source(agent.request),
      ]
    case .command(let command):
      lines = [.plain(l10n.string(.intakeCommandFetch)), .source(command.script)]
      if let directory = command.directory {
        lines.append(.plain(l10n.string(.intakeDirectory) + "  " + directory))
      }
    }
    lines.append(.plain(coverage(fetch.coverage)))
    return lines
  }

  /// 判定の行の並び: CLI・モデルと指示文。
  func judge(_ judge: IntakeJudge) -> [Line] {
    [.plain([judge.cli, judge.model].joined(separator: " · ")), .source(judge.instruction)]
  }

  /// 取得の性質と、それで候補がいつ下がるか。
  func coverage(_ coverage: IntakeCoverage) -> String {
    switch coverage {
    case .currentSet: l10n.string(.intakeCurrentSet)
    case .newArrivals: l10n.string(.intakeNewArrivals)
    }
  }

  /// 「30 分ごと」「毎日 9:00・13:00」。
  func when(_ timing: BackgroundTiming) -> String {
    switch timing {
    case .every(let interval):
      return l10n.format(.intakeEvery, Int(interval / 60))
    case .daily(let times):
      let sorted = times.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
      return l10n.format(
        .intakeDaily,
        sorted.map { Self.clock(hour: $0.hour, minute: $0.minute) }.joined(separator: "・"))
    }
  }

  /// 「次 17:00」（今日でなければ日付付き）。
  func next(_ date: Date) -> String {
    l10n.format(.intakeNext, stamp(date))
  }

  /// 「期限 10/10（金）」。
  func due(_ due: TaskItem.DueDate) -> String {
    l10n.format(
      .intakeDue, TaskDueText.date(due, today: today),
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
