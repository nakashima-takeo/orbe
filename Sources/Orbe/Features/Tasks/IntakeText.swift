import Foundation

/// 受信タブに出す文（時刻・回の要約・いつ）。暦日は画面を開いた時点の今日とタイムゾーンで決める。
struct IntakeText {
  let l10n: LocalizationStore
  let today: TaskItem.DueDate
  let timeZone: TimeZone

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
    return day == today ? "\(l10n.string(.taskPaletteToday)) \(clock(date))" : stamp(date)
  }

  /// 行の右の時刻。今日なら「10:24」、ほかの日は「10/9」。
  func short(_ date: Date) -> String {
    let day = TaskItem.DueDate(date, timeZone: timeZone)
    return day == today ? clock(date) : TaskDueText.date(day, today: today)
  }

  /// 提案の一覧の頭。「13:00 の回 · 9 件取得 → 新しい 4 件を判定 → 提案 2」。
  func runHeadline(_ run: IntakeRun?) -> String {
    guard let run else { return l10n.string(.taskPaletteIntakeNeverRan) }
    return l10n.format(.taskPaletteIntakeRunAt, stamp(run.startedAt)) + " · "
      + steps(run, proposed: .taskPaletteIntakeProposedShort)
  }

  /// 受信の中身の前回。「今日 9:12 · 14 件取得 → 新しい 3 件を判定 → 1 件を提案」。
  func runDetail(_ run: IntakeRun?) -> String {
    guard let run else { return l10n.string(.taskPaletteIntakeNeverRan) }
    return moment(run.startedAt) + " · " + steps(run, proposed: .taskPaletteIntakeProposedLong)
  }

  private func steps(_ run: IntakeRun, proposed: L10nKey) -> String {
    if let failure = run.failure { return l10n.format(.taskPaletteIntakeFailed, failure) }
    var parts = [l10n.format(.taskPaletteIntakeFetched, run.fetch.items)]
    if run.newItems == 0 {
      parts.append(l10n.string(.taskPaletteIntakeNothingNew))
    } else {
      parts.append(l10n.format(.taskPaletteIntakeJudged, run.newItems))
      parts.append(l10n.format(proposed, run.judge?.proposed ?? 0))
    }
    return parts.joined(separator: " → ")
  }

  /// 取得の性質と、それで提案がいつ下がるか。
  func coverage(_ coverage: IntakeCoverage) -> String {
    switch coverage {
    case .currentSet: l10n.string(.taskPaletteIntakeCurrentSet)
    case .newArrivals: l10n.string(.taskPaletteIntakeNewArrivals)
    }
  }

  /// 「30 分ごと」「毎日 9:00・13:00」。
  func when(_ timing: BackgroundTiming) -> String {
    switch timing {
    case .every(let interval):
      return l10n.format(.taskPaletteIntakeEvery, Int(interval / 60))
    case .daily(let times):
      let sorted = times.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
      return l10n.format(
        .taskPaletteIntakeDaily,
        sorted.map { Self.clock(hour: $0.hour, minute: $0.minute) }.joined(separator: "・"))
    }
  }

  /// 「期限 10/10（金）」。
  func due(_ due: TaskItem.DueDate) -> String {
    l10n.format(
      .taskPaletteIntakeDue, TaskDueText.date(due, today: today),
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
