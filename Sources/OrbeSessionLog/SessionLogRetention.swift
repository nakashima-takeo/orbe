import Foundation

/// 保持規則（純関数）。30 日より古い行を落とし、なお合計が 5MB を超えるあいだ古い側から落とす。
public enum SessionLogRetention {
  public static let defaultRetention: TimeInterval = 30 * 86400
  public static let defaultMaxBytes = 5 * 1024 * 1024

  public static func prune(
    _ events: [SessionEvent], now: Date, retention: TimeInterval = defaultRetention,
    maxBytes: Int = defaultMaxBytes
  ) -> [SessionEvent] {
    let cutoff = now.addingTimeInterval(-retention)
    let recent = events.filter { $0.ts >= cutoff }
    var total = 0
    var start = recent.endIndex
    while start > recent.startIndex {
      let size = (try? SessionLogWriter.encodeLine(recent[start - 1]).count) ?? 0
      guard total + size <= maxBytes else { break }
      total += size
      start -= 1
    }
    return Array(recent[start...])
  }
}
