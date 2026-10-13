import Foundation

/// 5 欄（分 時 日 月 曜日）の cron 式。解析を通ってしか作れず、作れた値はいつか必ず来て、日と曜日の少なくとも一方は `*`
/// ——だから日・曜日・月・時・分はすべて「かつ」で数える（標準 cron の「どちらか一致」になる式は通さない）。
struct BackgroundCron: Equatable {
  /// 受けた式（前後の空白を除く）。保存・外の口・式のままの表示はこれを使う。
  let expression: String
  let minutes: Set<Int>
  let hours: Set<Int>
  let days: Set<Int>
  let months: Set<Int>
  /// 0 が日曜。
  let weekdays: Set<Int>

  init(_ text: String) throws(BackgroundCronError) {
    expression = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
    guard fields.count == 5 else { throw .fieldCount }
    minutes = try Self.parse(fields[0], .minute)
    hours = try Self.parse(fields[1], .hour)
    days = try Self.parse(fields[2], .day)
    months = try Self.parse(fields[3], .month)
    weekdays = Set(try Self.parse(fields[4], .weekday).map { $0 % 7 })
    // 標準 cron は「絞ったか」を値でなく書き方で決める（`1-31` も絞ったことになる）。
    guard fields[2] == "*" || fields[4] == "*" else { throw .dayAndWeekday }
    guard days.contains(where: { day in months.contains { day <= Self.longestMonth[$0 - 1] } })
    else { throw .neverMatches }
  }

  /// `anchor` より後で、かつ `floor` 以降の最初の該当時刻（秒 0）。`zoned` からはタイムゾーンだけを使い、暦は利用者の暦法に
  /// 依らず西暦で数える——式の日・月は西暦の日・月。夏時間で存在しない時刻は次に存在する時刻へ、繰り返す時刻は最初の方を取る。
  func next(after anchor: Date, notBefore floor: Date, calendar zoned: Calendar) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zoned.timeZone
    let hours = hours.sorted()
    let minutes = minutes.sorted()
    var day = calendar.startOfDay(for: max(anchor, floor))
    for _ in 0..<Self.searchDays {
      if matches(day: day, calendar: calendar) {
        func due(_ hour: Int, _ minute: Int) -> Date? {
          calendar.date(
            bySettingHour: hour, minute: minute, second: 0, of: day,
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward
          ).flatMap { $0 > anchor && $0 >= floor ? $0 : nil }
        }
        // 1 時間の中の該当時刻は時の順に並ぶので、最後の分が届かない時はまるごと飛ばす。
        for hour in hours where due(hour, minutes[minutes.count - 1]) != nil {
          if let date = minutes.lazy.compactMap({ due(hour, $0) }).first { return date }
        }
      }
      guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = following
    }
    return .distantFuture
  }

  private func matches(day: Date, calendar: Calendar) -> Bool {
    let c = calendar.dateComponents([.month, .day, .weekday], from: day)
    guard let month = c.month, let dayOfMonth = c.day, let weekday = c.weekday else { return false }
    return months.contains(month) && days.contains(dayOfMonth) && weekdays.contains(weekday - 1)
  }

  /// 2 月は 29 日（閏年に来る）。
  private static let longestMonth = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  /// 2 月 29 日だけの式の間隔（最長 8 年）を含められる長さ。
  private static let searchDays = 366 * 8 + 1

  enum Field: String {
    case minute, hour, day, month, weekday

    var range: ClosedRange<Int> {
      switch self {
      case .minute: 0...59
      case .hour: 0...23
      case .day: 1...31
      case .month: 1...12
      case .weekday: 0...7
      }
    }

    var names: [String] {
      switch self {
      case .month:
        ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
      case .weekday: ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
      case .minute, .hour, .day: []
      }
    }

    /// 名前の 1 番目が表す数（月は 1、曜日は 0）。
    var firstNamed: Int { self == .month ? 1 : 0 }
  }

  private static func parse(_ text: String, _ field: Field) throws(BackgroundCronError) -> Set<Int>
  {
    var values = Set<Int>()
    for item in text.split(separator: ",", omittingEmptySubsequences: false) {
      guard let part = parseItem(Substring(item), field) else {
        throw .invalidField(field, text)
      }
      values.formUnion(part)
    }
    return values
  }

  /// `*`・`a`・`a-b` に、刻み `/n` を付けたもの。`a/n` は a から欄の最大まで。
  private static func parseItem(_ item: Substring, _ field: Field) -> Set<Int>? {
    let pieces = item.split(separator: "/", omittingEmptySubsequences: false)
    guard (1...2).contains(pieces.count) else { return nil }
    var step = 1
    if pieces.count == 2 {
      guard let n = number(pieces[1]), n > 0 else { return nil }
      step = n
    }
    let lower: Int
    let upper: Int
    if pieces[0] == "*" {
      (lower, upper) = (field.range.lowerBound, field.range.upperBound)
    } else {
      let bounds = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
      guard (1...2).contains(bounds.count),
        let first = value(bounds[0], field),
        let last = bounds.count == 2 ? value(bounds[1], field) : first
      else { return nil }
      (lower, upper) = (
        first, bounds.count == 1 && pieces.count == 2 ? field.range.upperBound : last
      )
    }
    guard lower <= upper else { return nil }
    return Set(stride(from: lower, through: upper, by: step))
  }

  private static func value(_ text: Substring, _ field: Field) -> Int? {
    let named = field.names.firstIndex(of: text.lowercased()).map { $0 + field.firstNamed }
    guard let value = named ?? number(text), field.range.contains(value) else { return nil }
    return value
  }

  private static func number(_ text: Substring) -> Int? {
    guard !text.isEmpty, text.count <= 4, text.allSatisfy({ $0.isASCII && $0.isNumber }) else {
      return nil
    }
    return Int(text)
  }
}

enum BackgroundCronError: Error, Equatable {
  case fieldCount
  case invalidField(BackgroundCron.Field, String)
  case dayAndWeekday
  case neverMatches
}
