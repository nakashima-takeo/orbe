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
        "link": proposal.item.link, "body": proposal.item.body,
        "time": SessionEvent.iso8601(proposal.item.time),
        "proposedAt": SessionEvent.iso8601(proposal.proposedAt),
      ]
      if let shelf {
        json["automationId"] = shelf.id
        json["automationName"] = shelf.definition.name
      }
      if let due = proposal.due { json["due"] = due.text }
      if case .accepted(let taskId) = proposal.state { json["taskId"] = taskId }
      return json
    }
    return .success(["proposals": proposals])
  }

  /// 定義（保存のまま）に、止めているか・走っているか・次の時刻・前回・出力先ごとの欄・回の記録（保存と同じ形）を足す。
  private func automationJSON(_ automation: Automation) -> [String: Any] {
    var json: [String: Any] = [
      "automationId": automation.id,
      "definition": AutomationWire.object(automation.definition),
      "paused": automation.paused,
      "running": automationRunner.isRunning(automation.id),
      "runs": AutomationWire.object(automation.runs),
    ]
    if let next = automationRunner.nextRunAt(automation) {
      json["nextRunAt"] = SessionEvent.iso8601(next)
    }
    if let last = automation.lastRunAt { json["lastRunAt"] = SessionEvent.iso8601(last) }
    switch automation.definition.sink {
    case .taskCandidates:
      json["taskCandidates"] =
        [
          "openProposals": automationStore.proposals.filter {
            $0.state == .open && automationStore.shelf(of: $0)?.id == automation.id
          }.count,
          "overlaps": automationStore.overlaps(of: automation.id).map {
            [
              "automationId": $0.automation.id, "name": $0.automation.definition.name,
              "count": $0.count,
            ] as [String: Any]
          },
        ] as [String: Any]
    case .command: break
    }
    return json
  }

  private static func automationNotFound(_ id: Int) -> ControlError {
    ControlError(code: -32004, message: "automation not found: \(id)")
  }

  /// ドメインエラーを制御エラーの語彙へ写す（未知 → -32004・不正な値 → -32602・走っている → -32000）。
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
        return .failure(ControlError(code: -32000, message: "automation \(id) is running"))
      }
    }
  }
}
