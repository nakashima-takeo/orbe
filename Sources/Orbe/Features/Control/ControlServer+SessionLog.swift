import Foundation
import OrbeSessionLog

/// `session_log`（読み取り専用・main ホップ不要）。制御キュー上で params を検証し、ファイルの読取は
/// background queue へ hop して応答だけを制御キューへ戻す——accept・配信・timeout を直列に捌く 1 本の
/// キューを最大 5MB の復号で塞がない。窓（target）を要さないので、Orbe が起きていれば常に答える。
extension ControlServer {
  static let sessionLogDefaultLimit = 1000
  static let sessionLogMaxLimit = 10000

  /// `session_log` の params。型違い・ISO 不正・limit の値域外は -32602。
  struct SessionLogQueryParams {
    let since: Date?
    let until: Date?
    let limit: Int
    let sessionId: String?

    static func parse(_ params: [String: Any]) -> Result<SessionLogQueryParams, ControlError> {
      func invalid(_ key: String) -> ControlError {
        ControlError(code: -32602, message: "invalid \(key)")
      }
      func date(_ key: String) -> Result<Date?, ControlError> {
        guard let raw = params[key] else { return .success(nil) }
        guard let text = raw as? String, let parsed = SessionEvent.parseISO8601(text) else {
          return .failure(invalid(key))
        }
        return .success(parsed)
      }
      guard case .success(let since) = date("since") else { return .failure(invalid("since")) }
      guard case .success(let until) = date("until") else { return .failure(invalid("until")) }
      var limit = sessionLogDefaultLimit
      if let raw = params["limit"] {
        guard let n = raw as? Int, (1...sessionLogMaxLimit).contains(n) else {
          return .failure(invalid("limit"))
        }
        limit = n
      }
      var sessionId: String?
      if let raw = params["sessionId"] {
        guard let text = raw as? String else { return .failure(invalid("sessionId")) }
        sessionId = text
      }
      return .success(
        SessionLogQueryParams(since: since, until: until, limit: limit, sessionId: sessionId))
    }
  }

  func sessionLog(id: Any?, params: [String: Any], conn: Connection) {
    let query: SessionLogQueryParams
    switch SessionLogQueryParams.parse(params) {
    case .success(let parsed): query = parsed
    case .failure(let error): return conn.respond(id: id, result: .failure(error))
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
