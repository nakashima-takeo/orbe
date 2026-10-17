import Foundation
import OrbeSessionLog

/// 自動化の 6 動詞の domain 側。変異は `AutomationRunner`（番人の登録を合わせる）、読みは `AutomationStore` に任せ、ここは応答の形を組む。
extension WindowController {
  func controlListAutomations() -> Result<Any, ControlError> {
    .success(["automations": automationStore.automations.map(automationJSON)])
  }

  func controlSetAutomation(automationId: Int?, _ definition: AutomationDefinition) -> Result<
    Any, ControlError
  > {
    automationResult { () throws(AutomationError) in
      ["automation": automationJSON(try automationRunner.set(automationId, definition))]
    }
  }

  func controlRunAutomation(automationId: Int) -> Result<Any, ControlError> {
    automationResult { () throws(AutomationError) in
      try automationRunner.runNow(automationId)
      return ["ok": true]
    }
  }

  func controlPauseAutomation(automationId: Int, paused: Bool) -> Result<Any, ControlError> {
    automationResult { () throws(AutomationError) in
      ["automation": automationJSON(try automationRunner.pause(automationId, paused))]
    }
  }

  func controlDeleteAutomation(automationId: Int) -> Result<Any, ControlError> {
    automationResult { () throws(AutomationError) in
      try automationRunner.delete(automationId)
      return ["ok": true]
    }
  }

  func controlListAutomationProposals(automationId: Int?) -> Result<Any, ControlError> {
    if let automationId, automationStore.automation(automationId) == nil {
      return .failure(Self.automationNotFound(automationId))
    }
    let proposals = automationStore.proposals.compactMap { proposal -> [String: Any]? in
      let shelf = automationStore.shelf(of: proposal)
      if let automationId, shelf?.id != automationId { return nil }
      var json: [String: Any] = [
        "proposalId": proposal.id, "state": proposal.state.name, "title": proposal.title,
        "partKey": proposal.partKey, "sourcePartKey": proposal.sourcePartKey,
        "link": proposal.item.link, "body": proposal.item.body,
        "time": SessionEvent.iso8601(proposal.item.time),
        "proposedAt": SessionEvent.iso8601(proposal.proposedAt),
      ]
      if let shelf {
        json["automationId"] = shelf.id
        json["automationName"] = shelf.name
      }
      if let due = proposal.due { json["due"] = due.text }
      if let ws = proposal.workspace.flatMap({ id in workspaces.first { $0.persistentId == id } }) {
        json["workspaceId"] = ws.id
        json["workspaceName"] = ws.name
      }
      if case .accepted(let taskId) = proposal.state { json["taskId"] = taskId }
      return json
    }
    return .success(["proposals": proposals])
  }

  /// 定義（保存のまま）に、止めているか・部品の鍵ごとの状態（走っているか・次の時刻・最後に回った時刻・溜まりの件数・決まりを
  /// 外した印・回の記録〔保存と同じ形〕）を足す。判定の部品を持つ自動化にだけタスク候補の欄を付ける。
  private func automationJSON(_ automation: Automation) -> [String: Any] {
    var parts: [String: Any] = [:]
    for node in automation.graph.nodes {
      let state = automation.state(node.key)
      var part: [String: Any] = [
        "running": automationRunner.isRunning(automation.id, node.key),
        "runs": AutomationWire.object(state.runs),
      ]
      if let next = automationRunner.nextRunAt(automation, part: node.key) {
        part["nextRunAt"] = SessionEvent.iso8601(next)
      }
      if let last = state.lastRunAt { part["lastRunAt"] = SessionEvent.iso8601(last) }
      if !node.part.inputs.isEmpty { part["inbox"] = state.inbox }
      if let breach = state.breach { part["breach"] = AutomationWire.object(breach) }
      parts[node.key] = part
    }
    var json: [String: Any] = [
      "automationId": automation.id,
      "definition": AutomationWire.object(automation.definition),
      "paused": automation.paused,
      "parts": parts,
    ]
    if automation.judges {
      json["taskCandidates"] =
        [
          "openProposals": automationStore.proposals.filter {
            $0.state == .open && automationStore.shelf(of: $0)?.id == automation.id
          }.count,
          "overlaps": automationStore.overlaps(of: automation.id).map {
            ["automationId": $0.automation.id, "name": $0.automation.name, "count": $0.count]
              as [String: Any]
          },
        ] as [String: Any]
    }
    return json
  }

  private static func automationNotFound(_ id: Int) -> ControlError {
    ControlError(code: -32004, message: "automation not found: \(id)")
  }

  /// ドメインエラーを制御エラーの語彙へ写す（未知 → -32004・不正な値 → -32602・走っている・使えない → -32000）。
  private func automationResult(_ body: () throws(AutomationError) -> [String: Any]) -> Result<
    Any, ControlError
  > {
    do throws(AutomationError) {
      return .success(try body())
    } catch {
      switch error {
      case .automationNotFound(let id): return .failure(Self.automationNotFound(id))
      case .proposalNotFound(let id):
        return .failure(ControlError(code: -32004, message: "proposal not found: \(id)"))
      case .proposalNotOpen(let id):
        return .failure(ControlError(code: -32602, message: "proposal \(id) is not open"))
      case .invalid(let message): return .failure(ControlError(code: -32602, message: message))
      case .running(let id):
        return .failure(
          ControlError(
            code: -32000, message: "every part of automation \(id) without from is running"))
      case .unavailable(let message):
        return .failure(ControlError(code: -32000, message: message))
      }
    }
  }
}
