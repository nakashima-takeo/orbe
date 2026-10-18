import Foundation

/// 自動化を人に見せる文（時刻・部品の役割と予定・いつ。回の失敗と外れた行は `AutomationText+Run`）。何をどの順に出すかまでを決め、描き方（字の大きさ・箱）は
/// 使う画面が決める。暦日は渡された今日とタイムゾーンで決める。
struct AutomationText {
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
    return day == today ? "\(l10n.string(.automationToday)) \(clock(date))" : stamp(date)
  }

  /// 行の右の時刻。今日なら「10:24」、ほかの日は「10/9」。
  func short(_ date: Date) -> String {
    let day = TaskItem.DueDate(date, timeZone: timeZone)
    return day == today ? clock(date) : TaskDueText.date(day, today: today)
  }

  /// 一覧・地図の時刻。今日なら「16:41」、昨日なら「昨日 23:00」、ほかは「10/12 10:00」。
  func recent(_ date: Date) -> String {
    guard TaskItem.DueDate(date, timeZone: timeZone).days(to: today) == 1 else {
      return stamp(date)
    }
    return l10n.format(.automationYesterday, clock(date))
  }

  /// 部品の役割の名前（「取得」「判定」）。部品を名指す言い方には使わない——部品は名前だけで言い、役割は地図の役割の列と
  /// カードの頭でだけ見せる。
  func role(_ role: AutomationPartRole) -> String {
    switch role {
    case .fetch: l10n.string(.automationRoleFetch)
    case .process: l10n.string(.automationRoleProcess)
    case .judge: l10n.string(.automationRoleJudge)
    case .report: l10n.string(.automationRoleReport)
    case .work: l10n.string(.automationRoleWork)
    case .sideEffect: l10n.string(.automationRoleSideEffect)
    }
  }

  /// 部品の予定（「30分ごと」「平日 9:00」「手動」「前の部品に連動」）。
  func schedule(_ trigger: AutomationPart.Trigger) -> String {
    switch trigger {
    case .scheduled(let timing): when(timing)
    case .manual: l10n.string(.automationManual)
    case .arrival: l10n.string(.automationArrival)
    }
  }

  /// 「30分ごと」「平日 9:00」「平日 9:00〜18:50 の10分ごと」。言葉にしない cron 式は「cron <式>」で、式の欄の間は
  /// 改行しない空白にする——狭い面で式の途中で折れると、欄が別の行に分かれて読み違える。
  func when(_ timing: BackgroundTiming) -> String {
    switch timing {
    case .every(let interval): l10n.format(.automationEvery, Int(interval / 60))
    case .cron(let cron):
      words(cron)
        ?? "cron "
        + cron.expression.split(whereSeparator: \.isWhitespace).joined(separator: "\u{00A0}")
    }
  }

  /// 「次回 17:00」（今日でなければ日付付き）。
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

  static func clock(hour: Int, minute: Int) -> String {
    String(format: "%d:%02d", hour, minute)
  }
}
