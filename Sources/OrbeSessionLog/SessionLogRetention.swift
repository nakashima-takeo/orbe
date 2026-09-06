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
    var kept = events.filter { $0.ts >= cutoff }
    var sizes = kept.map { (try? SessionLogWriter.encodeLine($0).count) ?? 0 }
    var total = sizes.reduce(0, +)
    while total > maxBytes, !kept.isEmpty {
      total -= sizes.removeFirst()
      kept.removeFirst()
    }
    return kept
  }
}
