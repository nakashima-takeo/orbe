import Foundation
import OrbeSessionLog

/// 自動化の 9 動詞の domain 側。変異は `AutomationRunner`（番人の登録を合わせる）、読みは `AutomationStore`、試走は
/// `AutomationTrials` に任せ、ここは応答の形を組む。
extension WindowController {
  /// 自動化を ID 順に（定義を読めない自動化も、その場所に）。使えないセッションでは理由で断る。
  func controlListAutomations() -> Result<Any, ControlError> {
    automationResult { () throws(AutomationError) in
      guard automationStore.available else { throw automationStore.unavailableError }
      let readable = automationStore.automations.map { ($0.id, automationJSON($0)) }
      let unreadable = automationStore.unreadable.map { ($0.id, unreadableJSON($0)) }
      return ["automations": (readable + unreadable).sorted { $0.0 < $1.0 }.map(\.1)]
    }
  }

  func controlSetAutomation(
    automationId: Int?, version: Int?, _ definition: AutomationDefinition
  ) -> Result<Any, ControlError> {
    automationResult { () throws(AutomationError) in
      [
        "automation": automationJSON(
          try automationRunner.set(automationId, version: version, definition))
      ]
    }
  }

  func controlRunAutomation(automationId: Int, partKey: String?) -> Result<Any, ControlError> {
    automationResult { () throws(AutomationError) in
      let automation = automationStore.automations[try automationStore.index(automationId)]
      var target = AutomationFlow.Target.ends
      if let partKey {
        guard let node = automation.graph.node(key: partKey) else {
          throw .partNotFound(automationId, partKey)
        }
        target = .part(node.id)
      }
      try automationRunner.flow(automationId, to: target)
      return ["ok": true]
    }
  }

  /// 回の記録を新しい順に 1 ページ。
  func controlListAutomationRuns(automationId: Int, partKey: String?, before: Int?, limit: Int?)
    -> Result<Any, ControlError>
  {
    automationResult { () throws(AutomationError) in
      let page = try automationStore.history(
        of: automationId, part: partKey, before: before, limit: limit)
      var json: [String: Any] = [
        "runs": page.runs.map { run -> [String: Any] in
          let key = page.keys[run.part] ?? "\(run.part)"
          var object = AutomationRunWire.object(run.record, part: key)
          object["partKey"] = key
          return object
        }
      ]
      if let next = page.next { json["next"] = next }
      return json
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
      if let reason = proposal.reason { json["reason"] = reason }
      // 出した自動化と部品の鍵は組で出す——棚の自動化（`automationId`）と別のことがあり、鍵だけでは取り違える。出した自動化が
      // 消えた後は、指す先が無いので出さない。部品は今の鍵で言い、外れていれば出さない。
      if let issuer = proposal.automationId.flatMap(automationStore.automation) {
        var by: [String: Any] = ["automationId": issuer.id]
        if let judge = issuer.graph.node(proposal.judge) { by["partKey"] = judge.key }
        if let source = issuer.graph.node(proposal.source) { by["sourcePartKey"] = source.key }
        json["proposedBy"] = by
      }
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

  func controlTryAutomation(automationId: Int, _ request: AutomationTrial.Request) -> Result<
    Any, ControlError
  > {
    automationResult { () throws(AutomationError) in
      ["trial": trialJSON(try automationTrials.start(automationId, request))]
    }
  }

  func controlAutomationTrial(
    automationId: Int, wait: Bool, timeoutMs: Int,
    completion: @escaping (Result<Any, ControlError>) -> Void
  ) {
    guard wait else {
      return completion(
        automationResult { () throws(AutomationError) in
          ["trial": trialJSON(try automationTrials.trial(automationId))]
        })
    }
    automationTrials.wait(automationId, timeout: .milliseconds(timeoutMs)) { result, timedOut in
      completion(
        self.automationResult { () throws(AutomationError) in
          var json: [String: Any] = ["trial": self.trialJSON(try result.get())]
          if timedOut { json["timedOut"] = true }
          return json
        })
    }
  }

  private func trialJSON(_ trial: AutomationTrial) -> [String: Any] {
    trial.json { id in
      workspaces.first { $0.persistentId == id }.map { ($0.id, $0.name) }
    }
  }

  /// 定義（部品に `id` を添えた外の形）と版に、止めているか・部品の今の鍵ごとの状態（走っているか・最新の回・次の時刻・最後に
  /// 回った時刻・読めば取る行の数・決まりを外した印）を足す。判定の部品を持つ自動化にだけタスク候補の欄を付ける。
  private func automationJSON(_ automation: Automation) -> [String: Any] {
    var parts: [String: Any] = [:]
    for node in automation.graph.nodes {
      let state = automation.state(node.id)
      var part: [String: Any] = ["running": automationRunner.isRunning(automation.id, node.id)]
      if let last = state.runs.first {
        part["lastRun"] = AutomationRunWire.object(last, part: node.key)
      }
      if let next = automationRunner.nextRunAt(automation, part: node.id) {
        part["nextRunAt"] = SessionEvent.iso8601(next)
      }
      if let last = state.lastRunAt { part["lastRunAt"] = SessionEvent.iso8601(last) }
      if !node.inputs.isEmpty { part["inbox"] = state.inbox }
      if let breach = state.breach { part["breach"] = AutomationRunWire.object(breach) }
      parts[node.key] = part
    }
    var json: [String: Any] = [
      "automationId": automation.id,
      "version": automation.version,
      "definition": AutomationWire.object(automation.definition),
      "paused": automation.paused,
      "parts": parts,
    ]
    if automation.judges {
      json["taskCandidates"] =
        [
          "openProposals": automationStore.shelvedProposals(of: automation.id).count,
          "overlaps": automationStore.overlaps(of: automation.id).map {
            ["automationId": $0.automation.id, "name": $0.automation.name, "count": $0.count]
              as [String: Any]
          },
        ] as [String: Any]
    }
    return json
  }

  /// 定義を読めない自動化: 行から組めた分の定義・版・理由。
  private func unreadableJSON(_ broken: AutomationUnreadable) -> [String: Any] {
    [
      "automationId": broken.id, "version": broken.version,
      "definition": (try? JSONSerialization.jsonObject(with: Data(broken.definition.utf8)))
        ?? [String: Any](),
      "definitionError": broken.reason,
    ]
  }

  private static func automationNotFound(_ id: Int) -> ControlError {
    ControlError(code: -32004, message: "automation not found: \(id)")
  }

  /// ドメインエラーを制御エラーの語彙へ写す（未知・試走が無い → -32004・不正な値 → -32602・流している途中・使えない → -32000）。
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
      case .partNotFound(let id, let key):
        return .failure(
          ControlError(code: -32004, message: "part not found: \(key) in automation \(id)"))
      case .flowing(let id):
        return .failure(
          ControlError(
            code: -32000,
            message: "automation \(id) is still flowing; wait until its parts finish"))
      case .unavailable(let message):
        return .failure(ControlError(code: -32000, message: message))
      case .trialNotFound(let id):
        return .failure(ControlError(code: -32004, message: "no trial of automation \(id)"))
      case .versionMismatch(let sent, let current):
        return .failure(
          ControlError(
            code: -32000,
            message:
              "version mismatch: sent \(sent), current \(current); read it again with list_automations"
          ))
      case .unreadable(let id, let reason):
        return .failure(
          ControlError(
            code: -32000,
            message:
              "automation \(id) cannot be read: \(reason); fix it with set_automation or delete it")
        )
      }
    }
  }
}
