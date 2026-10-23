import Foundation
import OrbeSessionLog

/// 試走の外の形（`try_automation` / `get_automation_trial` の `trial`）。部品の回は本番の `runs` の要素から `recordId`・`partKey` を
/// 除いた形に中身を足す。
extension AutomationTrial {
  /// `workspace` は候補の付け先（`Workspace.persistentId`）を今の workspace の id と名前に解く。
  func json(workspace: (UUID) -> (id: Int, name: String)?) -> [String: Any] {
    var json: [String: Any] = [
      "automationId": automationId, "from": keys(range.from), "to": keys(range.to),
      "startedAt": SessionEvent.iso8601(startedAt), "running": running, "preparing": preparing,
      "parts": range.path.map { node -> [String: Any] in
        [
          "key": node.key, "state": state(of: node.id).rawValue,
          "runs": (passes[node.id] ?? []).map { $0.json(part: node.key, workspace: workspace) },
        ]
      },
    ]
    if let limit = request.limit { json["limit"] = limit }
    if let endedAt { json["endedAt"] = SessionEvent.iso8601(endedAt) }
    if let failure { json["failure"] = failure }
    return json
  }

  private func keys(_ ids: [AutomationPartID]) -> [String] {
    ids.compactMap { id in range.path.first { $0.id == id }?.key }
  }
}

extension AutomationTrial.Pass {
  /// 止めた副作用・仕事と与えた取得は、手段を起こしていないので回の記録を持たず、行だけ。
  fileprivate func json(part: String, workspace: (UUID) -> (id: Int, name: String)?) -> [String:
    Any]
  {
    switch self {
    case .held(let rows): return ["held": ["rows": Self.objects(rows)]]
    case .given(let rows): return ["given": ["rows": Self.objects(rows)]]
    case .ran(let run, let content):
      var json = AutomationRunWire.object(run, part: part)
      switch content {
      case .rows(let rows):
        json["rows"] = Self.objects(rows)
      case .judged(let proposals, let resolved):
        json["proposals"] = proposals.map { proposal -> [String: Any] in
          var item: [String: Any] = [
            "id": AutomationDatabase.downstreamId(
              proposal.origin.item.id, of: proposal.origin.part, inherited: false),
            "link": proposal.origin.item.link, "title": proposal.title,
          ]
          if let due = proposal.due { item["due"] = due.text }
          if let reason = proposal.reason { item["reason"] = reason }
          if let ws = proposal.workspace.flatMap(workspace) {
            item["workspaceId"] = ws.id
            item["workspaceName"] = ws.name
          }
          return item
        }
        json["resolved"] = resolved
      case .none:
        break
      }
      return json
    }
  }

  private static func objects(_ rows: [String]) -> [Any] {
    rows.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
  }
}
