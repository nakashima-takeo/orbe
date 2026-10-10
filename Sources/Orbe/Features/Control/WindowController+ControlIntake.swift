import Foundation
import OrbeSessionLog

/// 受信の 6 動詞の domain 側。変異は `IntakeRunner`（番人の登録を合わせる）、読みは `IntakeStore` に任せ、ここは応答の形を組む。
extension WindowController {
  func controlListIntakes() -> Result<Any, ControlError> {
    .success(["intakes": intakeStore.intakes.map(intakeJSON)])
  }

  func controlSetIntake(intakeId: Int?, _ definition: IntakeDefinition) -> Result<Any, ControlError>
  {
    intakeResult { () throws(IntakeError) in
      ["intake": intakeJSON(try intakeRunner.set(intakeId, definition))]
    }
  }

  func controlRunIntake(intakeId: Int) -> Result<Any, ControlError> {
    intakeResult { () throws(IntakeError) in
      try intakeRunner.runNow(intakeId)
      return ["ok": true]
    }
  }

  func controlPauseIntake(intakeId: Int, paused: Bool) -> Result<Any, ControlError> {
    intakeResult { () throws(IntakeError) in
      ["intake": intakeJSON(try intakeRunner.pause(intakeId, paused))]
    }
  }

  func controlDeleteIntake(intakeId: Int) -> Result<Any, ControlError> {
    intakeResult { () throws(IntakeError) in
      try intakeRunner.delete(intakeId)
      return ["ok": true]
    }
  }

  func controlListIntakeProposals(intakeId: Int?) -> Result<Any, ControlError> {
    if let intakeId, intakeStore.intake(intakeId) == nil {
      return .failure(Self.intakeNotFound(intakeId))
    }
    let proposals = intakeStore.proposals.compactMap { proposal -> [String: Any]? in
      let shelf = intakeStore.shelf(of: proposal)
      if let intakeId, shelf?.id != intakeId { return nil }
      var json: [String: Any] = [
        "proposalId": proposal.id, "state": proposal.state.name, "title": proposal.title,
        "link": proposal.item.link, "body": proposal.item.body,
        "time": SessionEvent.iso8601(proposal.item.time),
        "proposedAt": SessionEvent.iso8601(proposal.proposedAt),
      ]
      if let shelf {
        json["intakeId"] = shelf.id
        json["intakeName"] = shelf.definition.name
      }
      if let due = proposal.due { json["due"] = due.text }
      if case .accepted(let taskId) = proposal.state { json["taskId"] = taskId }
      return json
    }
    return .success(["proposals": proposals])
  }

  /// 定義（set_intake と同じ形）に、止めているか・走っているか・次の時刻・出ている提案の数・重なり・回の記録を足す。
  private func intakeJSON(_ intake: Intake) -> [String: Any] {
    var json = IntakeWire.object(intake.definition) as? [String: Any] ?? [:]
    json["intakeId"] = intake.id
    json["paused"] = intake.paused
    json["running"] = intakeRunner.isRunning(intake.id)
    if let next = intakeRunner.nextRunAt(intake) { json["nextRunAt"] = SessionEvent.iso8601(next) }
    if let last = intake.lastRunAt { json["lastRunAt"] = SessionEvent.iso8601(last) }
    json["openProposals"] =
      intakeStore.proposals.filter {
        $0.state == .open && intakeStore.shelf(of: $0)?.id == intake.id
      }.count
    json["overlaps"] = intakeStore.overlaps(of: intake.id).map {
      ["intakeId": $0.intake.id, "name": $0.intake.definition.name, "count": $0.count]
        as [String: Any]
    }
    json["runs"] = IntakeWire.object(intake.runs)
    return json
  }

  private static func intakeNotFound(_ id: Int) -> ControlError {
    ControlError(code: -32004, message: "intake not found: \(id)")
  }

  /// ドメインエラーを制御エラーの語彙へ写す（未知 → -32004・不正な値 → -32602・走っている → -32000）。
  private func intakeResult(_ body: () throws(IntakeError) -> [String: Any]) -> Result<
    Any, ControlError
  > {
    do throws(IntakeError) {
      return .success(try body())
    } catch {
      switch error {
      case .intakeNotFound(let id): return .failure(Self.intakeNotFound(id))
      case .proposalNotFound(let id):
        return .failure(ControlError(code: -32004, message: "proposal not found: \(id)"))
      case .proposalNotOpen(let id):
        return .failure(ControlError(code: -32602, message: "proposal \(id) is not open"))
      case .invalid(let message): return .failure(ControlError(code: -32602, message: message))
      case .running(let id):
        return .failure(ControlError(code: -32000, message: "intake \(id) is running"))
      }
    }
  }
}
