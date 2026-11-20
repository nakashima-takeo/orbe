import Foundation
import OrbeSessionLog

/// `session_log`（読み取り専用・main ホップ不要）。制御キュー上で params を検証し、ファイルの読取は
/// background queue へ hop して応答だけを制御キューへ戻す——accept・配信・timeout を直列に捌く 1 本の
/// キューを最大 5MB の復号で塞がない。窓（target）を要さないので、Orbe が起きていれば常に答える。
extension ControlServer {
  /// `session_log` の引数。型違い・ISO 不正・limit の値域外は -32602。
  struct SessionLogQueryParams {
    let since: Date?
    let until: Date?
    let limit: Int
    let sessionId: String?

    static func parse(_ p: ControlParams) throws(ControlError) -> SessionLogQueryParams {
      let since = try p.optionalString("since")
      let until = try p.optionalString("until")
      let limit = try p.optionalInt("limit")
      let sessionId = try p.optionalString("sessionId")
      func date(_ key: String, _ text: String?) throws(ControlError) -> Date? {
        guard let text else { return nil }
        guard let parsed = SessionEvent.parseISO8601(text) else { throw p.invalid(key) }
        return parsed
      }
      if let limit, !(1...SessionLogLimits.maxLimit).contains(limit) { throw p.invalid("limit") }
      return SessionLogQueryParams(
        since: try date("since", since), until: try date("until", until),
        limit: limit ?? SessionLogLimits.defaultLimit, sessionId: sessionId)
    }
  }

  func sessionLog(id: Any?, params p: ControlParams, conn: Connection) {
    let query: SessionLogQueryParams
    do throws(ControlError) {
      query = try SessionLogQueryParams.parse(p)
    } catch {
      return conn.respond(id: id, result: .failure(error))
    }
    guard let url = AgentSessionLog.fileURL else {
      return conn.respond(
        id: id, result: .failure(ControlError(code: -32000, message: "state dir unavailable")))
    }
    DispatchQueue.global(qos: .utility).async {
      let result: Result<Any, ControlError>
      do {
        let read = try SessionLogReader.read(
          url, since: query.since, until: query.until, limit: query.limit,
          sessionId: query.sessionId)
        result = .success([
          "events": try Self.jsonObjects(read.events), "truncated": read.truncated,
        ])
      } catch {
        result = .failure(ControlError(code: -32000, message: "session log unreadable"))
      }
      self.queue.async { conn.respond(id: id, result: result) }
    }
  }

  /// wire 形（ファイルの 1 行）と同じ辞書へ。`JSONEncoder` → `JSONSerialization` の往復で `ts` は文字列のまま。
  private static func jsonObjects(_ events: [SessionEvent]) throws -> [[String: Any]] {
    let data = try JSONEncoder().encode(events)
    return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
  }
}
