import Foundation

/// 経過の長さ（「12分」「3時間」「2日」）と、それに「前」を付けた相対時刻（「12分前」。1 分未満は「たった今」）。1 時間未満は
/// 分、1 日未満は時間、それ以上は日。
enum ElapsedText {
  static func label(since: Date, now: Date, language: Language) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
    if minutes < 60 { return L10n.format(.elapsedMinutes, language, minutes) }
    if minutes < 60 * 24 { return L10n.format(.elapsedHours, language, minutes / 60) }
    return L10n.format(.elapsedDays, language, minutes / (60 * 24))
  }

  static func ago(_ date: Date, now: Date, language: Language) -> String {
    guard now.timeIntervalSince(date) >= 60 else { return L10n.string(.relativeJustNow, language) }
    return L10n.format(.relativeAgo, language, label(since: date, now: now, language: language))
  }
}
