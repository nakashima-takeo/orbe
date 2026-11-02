import Foundation
import OrbeSessionLog

/// 自動化の 9 動詞と、裏の agent の回の道具の domain 側。変異は `AutomationRunner`（番人の登録を合わせる）、読みは `AutomationStore`、試走は
/// `AutomationTrials` に任せ、ここは書き込みの入口（定義を読み、書く定義の workspace の席が今の workspace を指すかを確かめ、ストアで
/// 確かめる）と試す対象を組み、応答の形を組む。
extension WindowController {
  /// 自動化を ID 順に（定義を読めない自動化も、その場所に）。使えないセッションでは理由で断る。
  func controlListAutomations() -> Result<Any, ControlError> {
    automationResult { () throws(AutomationError) in
      let readable = try automationStore.automations.map { automation throws(AutomationError) in
        (automation.id, try automationJSON(automation))
      }
      let unreadable = automationStore.unreadable.map { ($0.id, unreadableJSON($0)) }
      return ["automations": (readable + unreadable).sorted { $0.0 < $1.0 }.map(\.1)]
    }
  }

  func controlSetAutomation(
    automationId: Int?, version: Int?, _ definition: [String: Any]
  ) -> Result<Any, ControlError> {
    automationResult { () throws(AutomationError) in
      [
        "automation": try automationJSON(
          try automationRunner.set(try checkedWrite(automationId, version, definition)))
      ]
    }
  }

  /// 書き込みの入口（`set_automation` と、書く前の定義の `try_automation` が通る）。定義を読み、workspace の席を確かめ、ストアで
  /// 確かめる——断りの集合と順番が両方の口で同じになる。
  private func checkedWrite(_ automationId: Int?, _ version: Int?, _ definition: [String: Any])
    throws(AutomationError) -> AutomationStore.CheckedWrite
  {
    let definition = try AutomationDefinition.decode(definition)
    try automationRunner.workspaces().checkSeats(of: definition)
    return try automationStore.check(
      AutomationStore.Write(automationId, version: version, definition))
  }

  func controlRunAutomation(automationId: Int, nodeKey: String?) -> Result<Any, ControlError> {
    automationResult { () throws(AutomationError) in
      let automation = automationStore.automations[try automationStore.index(automationId)]
      var target = AutomationFlow.Target.ends
      if let nodeKey {
        guard let node = automation.graph.node(key: nodeKey) else {
          throw .nodeNotFound(automationId, nodeKey)
        }
        target = .node(node.id)
      }
      try automationRunner.flow(automationId, to: target)
      return ["ok": true]
    }
  }

  /// 回の記録を新しい順に 1 ページ。
  func controlListAutomationRuns(automationId: Int, nodeKey: String?, before: Int?, limit: Int?)
    -> Result<Any, ControlError>
  {
    automationResult { () throws(AutomationError) in
      let page = try automationStore.history(
        of: automationId, nodeKey: nodeKey, before: before, limit: limit)
      var json: [String: Any] = [
        "runs": page.runs.map { run -> [String: Any] in
          var object = AutomationRunWire.object(run.record, nodeKey: run.nodeKey)
          object["nodeKey"] = run.nodeKey
          return object
        }
      ]
      if let next = page.next { json["next"] = next }
      return json
    }
  }

  func controlPauseAutomation(automationId: Int, nodeKey: String?, paused: Bool) -> Result<
    Any, ControlError
  > {
    automationResult { () throws(AutomationError) in
      let automation = automationStore.automations[try automationStore.index(automationId)]
      var nodeId: AutomationNodeID?
      if let nodeKey {
        guard let node = automation.graph.node(key: nodeKey) else {
          throw .nodeNotFound(automationId, nodeKey)
        }
        nodeId = node.id
      }
      return [
        "automation": try automationJSON(
          try automationRunner.pause(automationId, nodeId: nodeId, paused))
      ]
    }
  }

  func controlDeleteAutomation(automationId: Int) -> Result<Any, ControlError> {
    automationResult { () throws(AutomationError) in
      try automationRunner.delete(automationId)
      return ["ok": true]
    }
  }

  func controlListAutomationProposals(automationId: Int?) -> Result<Any, ControlError> {
    automationResult { () throws(AutomationError) in
      if let automationId { _ = try automationStore.index(automationId) }
      return ["proposals": proposalsJSON(of: automationId)]
    }
  }

  /// 覚えている候補（`automationId` があればその自動化が出した分だけ）。
  private func proposalsJSON(of automationId: Int?) -> [[String: Any]] {
    let proposals = automationStore.proposals.compactMap { proposal -> [String: Any]? in
      let issuer = automationStore.issuer(of: proposal)
      if let automationId, issuer?.id != automationId { return nil }
      return proposalJSON(proposal, issuer: issuer)
    }
    // 読めない候補は、読めない記録と同じく分かる分だけで出す。
    let unreadable = automationStore.unreadableProposals.compactMap { proposal -> [String: Any]? in
      if let automationId, automationStore.issuerId(ofJudge: proposal.judge) != automationId {
        return nil
      }
      return ["proposalId": proposal.id, "link": proposal.link, "unreadable": true]
    }
    return proposals + unreadable
  }

  /// 候補 1 つ。出した自動化（`issuer`。定義を読めなければ nil）と、その判定のノード・出どころのノードを今の鍵で言う。出どころの
  /// ノードは外れていれば出さない。
  private func proposalJSON(_ proposal: AutomationProposal, issuer: Automation?) -> [String: Any] {
    var json: [String: Any] = [
      "proposalId": proposal.id, "state": proposal.state.name, "title": proposal.title,
      "link": proposal.link, "proposedAt": SessionEvent.iso8601(proposal.proposedAt),
    ]
    if let body = proposal.fields.body { json["body"] = body }
    if let time = proposal.fields.time { json["time"] = SessionEvent.iso8601(time) }
    if let reason = proposal.reason { json["reason"] = reason }
    if let issuer {
      json["automationId"] = issuer.id
      json["automationName"] = issuer.name
      if let judge = issuer.graph.node(proposal.judge) { json["nodeKey"] = judge.key }
      if let origin = issuer.graph.node(proposal.originNodeId) {
        json["originNodeKey"] = origin.key
      }
    }
    if let due = proposal.due { json["due"] = due.text }
    if let ws = proposal.workspace.flatMap({ id in workspaces.first { $0.id == id } }) {
      json["workspaceId"] = ws.id.uuidString
      json["workspaceName"] = ws.name
    }
    if case .accepted(let taskId) = proposal.state { json["taskId"] = taskId }
    return json
  }

  /// 裏で動く agent の回の道具を 1 つ呼ぶ。返事は道具の答え（中身の塊と、断ったか）。
  func controlRunTool(token: String, name: String, arguments: [String: Any]) -> Result<
    Any, ControlError
  > {
    guard let session = automationRunner.runSessions.session(token) else {
      return .failure(ControlError(code: -32004, message: "run not found (it has ended)"))
    }
    let reply = session.call(name, arguments)
    return .success(["texts": reply.texts, "isError": reply.isError])
  }

  func controlTryAutomation(
    automationId: Int?, version: Int?, definition: [String: Any]?,
    _ request: AutomationTrial.Request
  ) -> Result<Any, ControlError> {
    automationResult { () throws(AutomationError) in
      let target = try trialTarget(automationId, version, definition)
      return ["trial": trialJSON(try automationTrials.start(target, request))]
    }
  }

  /// 試す対象: 定義が無ければ保存した定義、あれば書き込みの入口を通した書く前の定義（`automationId` があれば直す定義、無ければ
  /// 新しい定義）。版は直す定義だけが持つ。
  private func trialTarget(_ automationId: Int?, _ version: Int?, _ definition: [String: Any]?)
    throws(AutomationError) -> AutomationTrial.Target
  {
    if version != nil, automationId == nil || definition == nil {
      throw .invalid("version: pass it only with automationId and definition, to try a rewrite")
    }
    guard let definition else {
      guard let automationId else { throw .invalid("missing automationId or definition") }
      return .saved(automationId)
    }
    return .unsaved(try checkedWrite(automationId, version, definition))
  }

  func controlAutomationTrial(
    trialId: Int, wait: Bool, timeoutMs: Int,
    completion: @escaping (Result<Any, ControlError>) -> Void
  ) {
    guard wait else {
      return completion(
        automationResult { () throws(AutomationError) in
          ["trial": trialJSON(try automationTrials.trial(trialId))]
        })
    }
    automationTrials.wait(trialId, timeout: .milliseconds(timeoutMs)) { result, timedOut in
      completion(
        self.automationResult { () throws(AutomationError) in
          var json: [String: Any] = ["trial": self.trialJSON(try result.get())]
          if timedOut { json["timedOut"] = true }
          return json
        })
    }
  }

  private func trialJSON(_ trial: AutomationTrial) -> [String: Any] {
    trial.json { id in workspaces.first { $0.id == id }?.name }
  }

  /// 定義（ノードに `id` を添えた外の形）と版に、止めているか・ノードの今の鍵ごとの状態（走っているか・ノード自身を止めているか・
  /// 最新の回・次の時刻・読めば取る行の数・決まりを外した印。判定は今の定義が出した候補への人の判断の数も）を足す。判定のノードを
  /// 持つ自動化にだけタスク候補の欄を付ける。
  private func automationJSON(_ automation: Automation) throws(AutomationError) -> [String: Any] {
    var nodeObjects: [String: Any] = [:]
    for node in automation.graph.nodes {
      let state = automation.state(node.id)
      var object: [String: Any] = [
        "running": automationRunner.isRunning(automation.id, node.id), "paused": state.paused,
      ]
      if let last = state.runs.first {
        object["lastRun"] = AutomationRunWire.object(last, nodeKey: node.key)
      }
      if let next = automationRunner.nextRunAt(automation, nodeId: node.id) {
        object["nextRunAt"] = SessionEvent.iso8601(next)
      }
      if !node.inputs.isEmpty { object["pending"] = state.pending.count }
      if let breach = state.breach { object["breach"] = AutomationRunWire.breach(breach) }
      if node.role == .judge {
        let counts = try automationStore.settlementCounts(of: node)
        object["accepted"] = counts.accepted
        object["dismissed"] = counts.dismissed
      }
      nodeObjects[node.key] = object
    }
    var json: [String: Any] = [
      "automationId": automation.id,
      "version": automation.version,
      "definition": AutomationWire.object(automation.definition),
      "paused": automation.paused,
      "nodes": nodeObjects,
    ]
    if automation.judges {
      json["taskCandidates"] = [
        "openProposals": automationStore.shelvedProposals(of: automation.id).count
      ]
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

  /// ドメインエラーを制御エラーのコードへ写す（未知 → -32004・不正な値 → -32602・道の重なる流し・使えない・版の食い違い・読めない
  /// → -32000）。文は `AutomationError.message`。自動化を使えないセッションでは、どの動詞も中身を見る前に理由で断る。
  private func automationResult(_ body: () throws(AutomationError) -> [String: Any]) -> Result<
    Any, ControlError
  > {
    do throws(AutomationError) {
      guard automationStore.available else { throw automationStore.unavailableError }
      return .success(try body())
    } catch {
      let code =
        switch error {
        case .automationNotFound, .proposalNotFound, .nodeNotFound, .trialNotFound: -32004
        case .proposalNotOpen, .invalid: -32602
        case .flowing, .unavailable, .versionMismatch, .unreadable: -32000
        }
      return .failure(ControlError(code: code, message: error.message))
    }
  }
}
