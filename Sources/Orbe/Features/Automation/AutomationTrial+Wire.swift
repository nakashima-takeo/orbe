import Foundation
import OrbeSessionLog

/// 試走の外の形（`try_automation` / `get_automation_trial` の `trial`）。ノードの回は本番の `runs` の要素から `recordId`・`nodeKey` を
/// 除いた形に中身を足す。新しい定義の試走は自動化を持たない（写しの上の自動化の ID は外に出さない——本番で後に作る自動化と重なり
/// うる）。
extension AutomationTrial {
  /// ノードの進み（外の形の `state`）。
  enum NodeState: String {
    case waiting
    case running
    case done
    /// 副作用・仕事のノードを止めて終えた。
    case held
    /// 与えた行を出力にした取得（手段を起こさない）。
    case given
    /// 打ち切りで、一度も動かなかった。
    case untouched
  }

  /// `workspaceName` は候補の付け先（`Workspace.id`）を今の workspace の名前に解く。
  func json(workspaceName: (UUID) -> String?) -> [String: Any] {
    var json: [String: Any] = [
      "trialId": id, "from": keys.from, "to": keys.to,
      "startedAt": SessionEvent.iso8601(startedAt), "running": running, "preparing": preparing,
      "nodes": nodesJSON(workspaceName: workspaceName),
    ]
    if let owner = target.owner { json["automationId"] = owner }
    if let limit = request.limit { json["limit"] = limit }
    if let endedAt { json["endedAt"] = SessionEvent.iso8601(endedAt) }
    if let failure { json["failure"] = failure }
    return json
  }

  private func nodesJSON(workspaceName: (UUID) -> String?) -> [[String: Any]] {
    guard let range else {
      return keys.path.map { ["key": $0, "state": unresolvedState.rawValue, "runs": [Any]()] }
    }
    return range.path.map { node in
      [
        "key": node.key, "state": state(of: node.id).rawValue,
        "runs": (passes[node.id] ?? []).map {
          $0.json(nodeKey: node.key, workspaceName: workspaceName)
        },
      ]
    }
  }
}

extension AutomationTrial.Pass {
  /// 本番で書いた時点に起きる分は `atWrite: true` を持つ。
  fileprivate func json(nodeKey: String, workspaceName: (UUID) -> String?) -> [String: Any] {
    var json = passJSON(nodeKey: nodeKey, workspaceName: workspaceName)
    if atWrite { json["atWrite"] = true }
    return json
  }

  /// 止めた副作用・仕事と与えた取得は、手段を起こしていないので回の記録を持たず、行だけ。
  private func passJSON(nodeKey: String, workspaceName: (UUID) -> String?) -> [String: Any] {
    switch self {
    case .held(let rows, _): return ["held": ["rows": Self.objects(rows)]]
    case .given(let rows): return ["given": ["rows": Self.objects(rows)]]
    case .ran(let run, let content, _):
      var json = AutomationRunWire.object(run, nodeKey: nodeKey)
      switch content {
      case .rows(let rows):
        json["rows"] = Self.objects(rows)
      case .judged(let proposals, let resolved):
        json["proposals"] = proposals.map { proposal -> [String: Any] in
          var item: [String: Any] = [
            "id": proposal.id, "link": proposal.fields.link, "title": proposal.title,
          ]
          if let due = proposal.due { item["due"] = due.text }
          if let reason = proposal.reason { item["reason"] = reason }
          if let id = proposal.workspace, let name = workspaceName(id) {
            item["workspaceId"] = id.uuidString
            item["workspaceName"] = name
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
