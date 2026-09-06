import Foundation

/// `agent-sessions.jsonl` の読み手。行の復号規則はここだけが持つ（起動時の剪定も `session_log` も
/// この `read` を通る）。
public enum SessionLogReader {
  /// ファイル順（昇順）で読む。不在は空。末尾に改行の無い最後の断片と復号できない行は読み飛ばす。`since <= ts <= until` と `sessionId` で絞り、`limit` を超えたら新しい側を残して
  /// `truncated` を立てる。
  public static func read(
    _ url: URL, since: Date? = nil, until: Date? = nil, limit: Int? = nil,
    sessionId: String? = nil
  ) throws -> (events: [SessionEvent], truncated: Bool) {
    guard FileManager.default.fileExists(atPath: url.path) else { return ([], false) }
    let data = try Data(contentsOf: url)
    var events = decodeLines(data).filter { event in
      if let since, event.ts < since { return false }
      if let until, event.ts > until { return false }
      if let sessionId, event.sessionId != sessionId { return false }
      return true
    }
    var truncated = false
    if let limit, events.count > limit {
      events = Array(events.suffix(limit))
      truncated = true
    }
    return (events, truncated)
  }

  private static func decodeLines(_ data: Data) -> [SessionEvent] {
    var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
    if data.last != 0x0A, !lines.isEmpty { lines.removeLast() }
    let decoder = JSONDecoder()
    return lines.compactMap { try? decoder.decode(SessionEvent.self, from: $0) }
  }
}
