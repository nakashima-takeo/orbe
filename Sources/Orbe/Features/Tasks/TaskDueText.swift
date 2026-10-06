import Foundation

/// 期限の文字の読み取りと、行と右の欄に出す暦日の表示。基準は今日の暦日で、時刻とタイムゾーンは
/// 呼び出し側が `TaskItem.DueDate.today(_:timeZone:)` で暦日へ落としてから渡す。
enum TaskDueText {
  /// 「10/6」（今日以降で最も近いその日）と「2026-10-06」を受ける。読めなければ nil。
  static func parse(_ text: String, today: TaskItem.DueDate) -> TaskItem.DueDate? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if let full = TaskItem.DueDate(trimmed) { return full }
    let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
    let isShortNumber = { (part: Substring) in
      (1...2).contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber }
    }
    guard parts.count == 2, parts.allSatisfy(isShortNumber),
      let month = Int(parts[0]), let day = Int(parts[1])
    else { return nil }
    // 2/29 のように今年に無い日は、その日がある最も近い年まで進める（閏年は 8 年以内に必ず来る）。
    for year in today.year...(today.year + 8) {
      guard let candidate = TaskItem.DueDate(year: year, month: month, day: day) else { continue }
      if candidate >= today { return candidate }
    }
    return nil
  }

  /// 「10/6 月」。今日と年が違えば年を付けて「2027/1/5 火」。`weekdays` は日曜始まりの曜日名。
  static func label(_ due: TaskItem.DueDate, today: TaskItem.DueDate, weekdays: [String])
    -> String
  {
    "\(date(due, today: today)) \(weekdays[due.weekday])"
  }

  /// 曜日なしの「10/6」。今日と年が違えば年を付けて「2027/1/5」。期限と追加日が同じ書式で出す。
  static func date(_ day: TaskItem.DueDate, today: TaskItem.DueDate) -> String {
    let monthDay = "\(day.month)/\(day.day)"
    return day.year == today.year ? monthDay : "\(day.year)/\(monthDay)"
  }

  /// 言語に合わせた日曜始まりの短い曜日名。
  static func weekdays(_ language: Language) -> [String] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = language.dateLocale
    return calendar.shortWeekdaySymbols
  }
}

extension TaskItem.DueDate: Comparable {
  init?(year: Int, month: Int, day: Int) {
    self.init(String(format: "%04d-%02d-%02d", year, month, day))
  }

  /// `date` がタイムゾーン `timeZone` で落ちる暦日。暦は利用者の設定に依らず西暦で数える——期限は
  /// 西暦の暦日として保存され、ほかの暦の年月日を入れると存在しない日付になる。
  init(_ date: Date, timeZone: TimeZone) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    self.init(year: c.year!, month: c.month!, day: c.day!)!
  }

  /// 今日の暦日。
  static func today(_ now: Date, timeZone: TimeZone) -> TaskItem.DueDate {
    TaskItem.DueDate(now, timeZone: timeZone)
  }

  static func < (a: TaskItem.DueDate, b: TaskItem.DueDate) -> Bool {
    (a.year, a.month, a.day) < (b.year, b.month, b.day)
  }

  /// 0 が日曜。
  var weekday: Int { Self.gregorianUTC.component(.weekday, from: midnight) - 1 }

  /// `self` から `other` までの暦日の差。
  func days(to other: TaskItem.DueDate) -> Int {
    Self.gregorianUTC.dateComponents([.day], from: midnight, to: other.midnight).day!
  }

  private var midnight: Date {
    Self.gregorianUTC.date(from: DateComponents(year: year, month: month, day: day))!
  }

  private static let gregorianUTC: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()
}
