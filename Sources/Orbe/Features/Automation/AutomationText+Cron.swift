import Foundation

/// cron 式を人の言葉にする。言い換えるのは元の時刻の集合を一意に表せる形だけで、範囲は最初と最後の該当時刻で書く。
/// どれにも当たらなければ nil（式のまま出す）。
extension AutomationText {
  func words(_ cron: BackgroundCron) -> String? {
    guard let day = day(cron), let time = time(cron) else { return nil }
    switch day {
    case .every where time.repeats: return time.text
    case .every: return l10n.string(.automationDaily) + " " + time.text
    case .some(let day): return day + " " + time.text
    }
  }

  private enum Day {
    case every
    case some(String)
  }

  private func day(_ cron: BackgroundCron) -> Day? {
    guard cron.months == Set(1...12) else { return nil }
    let separator = l10n.string(.automationListSeparator)
    if cron.days != Set(1...31) {
      return .some(
        l10n.format(
          cron.days.count == 1 ? .automationMonthlyOne : .automationMonthlyOther,
          cron.days.sorted().map { l10n.format(.automationMonthDay, $0) }.joined(
            separator: separator)))
    }
    switch cron.weekdays {
    case Set(0...6): return .every
    case Set(1...5): return .some(l10n.string(.automationWeekdays))
    case [0, 6]: return .some(l10n.string(.automationWeekends))
    default:
      let names = TaskDueText.weekdays(l10n.language)
      return .some(
        l10n.format(
          .automationWeekly, cron.weekdays.sorted().map { names[$0] }.joined(separator: separator)))
    }
  }

  /// `repeats` は時刻を並べず刻みで言った形（「毎日」を付けずに読める）。
  private func time(_ cron: BackgroundCron) -> (text: String, repeats: Bool)? {
    let hours = cron.hours.sorted()
    let minutes = cron.minutes.sorted()
    let clock = Self.clock
    if hours.count * minutes.count <= 4 {
      let times = hours.flatMap { hour in minutes.map { clock(hour, $0) } }
      return (l10n.format(.automationAt, times.joined(separator: " / ")), false)
    }
    if minutes.count > 1 {
      let step = minutes[1]
      guard 60 % step == 0, minutes == Array(stride(from: 0, to: 60, by: step)) else { return nil }
      guard hours == Array(hours[0]...hours[hours.count - 1]) else { return nil }
      let first = clock(hours[0], 0)
      let last = clock(hours[hours.count - 1], minutes[minutes.count - 1])
      return (l10n.format(.automationEveryMinutesBetween, first, last, step), true)
    }
    let minute = minutes[0]
    if hours.count == 24 { return (l10n.format(.automationHourly, minute), true) }
    let step = hours[1] - hours[0]
    guard hours == Array(stride(from: hours[0], through: hours[hours.count - 1], by: step)) else {
      return nil
    }
    let first = clock(hours[0], minute)
    let last = clock(hours[hours.count - 1], minute)
    return (l10n.format(.automationEveryHoursBetween, first, last, step), true)
  }
}
