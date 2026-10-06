import Foundation

/// agent がその状態になってからの経過（「12分」「3時間」「2日」）。1 時間未満は分、1 日未満は時間、それ以上は日。
enum TaskElapsedText {
  static func label(since: Date, now: Date, l10n: LocalizationStore) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
    if minutes < 60 { return l10n.format(.taskPaletteElapsedMinutes, minutes) }
    if minutes < 60 * 24 { return l10n.format(.taskPaletteElapsedHours, minutes / 60) }
    return l10n.format(.taskPaletteDays, minutes / (60 * 24))
  }
}
