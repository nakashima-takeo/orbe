import Foundation
import OrbeSessionLog

/// 試走の外の形（`try_automation` / `get_automation_trial` の `trial`）。部品の回は本番の `runs` の要素と同じ形に中身を足す。
extension AutomationTrial {
  /// `workspace` は候補の付け先（`Workspace.persistentId`）を今の workspace の id と名前に解く。
  func json(workspace: (UUID) -> (id: Int, name: String)?) -> [String: Any] {
    var json: [String: Any] = [
      "automationId": automationId, "from": range.from, "to": range.to,
      "startedAt": SessionEvent.iso8601(startedAt), "running": running, "preparing": preparing,
      "parts": range.path.map { node -> [String: Any] in
        [
          "key": node.key, "state": state(of: node.key).rawValue,
          "runs": (passes[node.key] ?? []).map { $0.json(workspace: workspace) },
        ]
      },
    ]
    if let limit = request.limit { json["limit"] = limit }
    if let endedAt { json["endedAt"] = SessionEvent.iso8601(endedAt) }
    if let failure { json["failure"] = failure }
    return json
  }
}

extension AutomationTrial.Pass {
  /// 止めた副作用・仕事は、写しの上の記録（手段を起こしていない）の代わりに渡るはずだった行だけ。
  fileprivate func json(workspace: (UUID) -> (id: Int, name: String)?) -> [String: Any] {
    if case .held(let rows) = content { return ["held": ["rows": Self.objects(rows)]] }
    var json = AutomationWire.object(run) as? [String: Any] ?? [:]
    switch content {
    case .rows(let rows):
      json["rows"] = Self.objects(rows)
    case .judged(let proposals, let resolved):
      json["proposals"] = proposals.map { proposal -> [String: Any] in
        var item: [String: Any] = [
          "id": "\(proposal.origin.part):\(proposal.origin.item.id)",
          "link": proposal.origin.item.link, "title": proposal.title,
        ]
        if let due = proposal.due { item["due"] = due.text }
        if let ws = proposal.workspace.flatMap(workspace) {
          item["workspaceId"] = ws.id
          item["workspaceName"] = ws.name
        }
        return item
      }
      json["resolved"] = resolved
    case .none, .held:
      break
    }
    return json
  }

  private static func objects(_ rows: [String]) -> [Any] {
    rows.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
  }
}
