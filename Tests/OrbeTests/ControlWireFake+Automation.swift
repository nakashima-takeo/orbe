import Foundation

@testable import Orbe

/// `set_automation` が届けたもの。
struct FakeSetAutomation {
  let automationId: Int?
  let version: Int?
  let definition: [String: Any]

  init(_ automationId: Int?, _ version: Int?, _ definition: [String: Any]) {
    self.automationId = automationId
    self.version = version
    self.definition = definition
  }
}

/// `pause_automation` が届けたもの。
struct FakePause {
  let automationId: Int
  let nodeKey: String?
  let paused: Bool
}

/// `list_automation_runs` が届けたもの。
struct FakeRunList {
  let nodeKey: String?
  let before: Int?
  let limit: Int?
}

/// `try_automation` が届けたもの。
struct FakeTry {
  let automationId: Int?
  let version: Int?
  let definition: [String: Any]?
  let request: AutomationTrial.Request
}

/// `run_tool` が届けたもの。
struct FakeRunTool {
  let token: String
  let name: String
  let arguments: [String: Any]
}

extension FakeControlTarget {
  func controlRunTool(token: String, name: String, arguments: [String: Any]) -> Result<
    Any, ControlError
  > {
    runTools.append(FakeRunTool(token: token, name: name, arguments: arguments))
    return outcome(["texts": [String](), "isError": false])
  }

  func controlTryAutomation(
    automationId: Int?, version: Int?, definition: [String: Any]?,
    _ request: AutomationTrial.Request
  ) -> Result<Any, ControlError> {
    triedAutomations.append(
      FakeTry(
        automationId: automationId, version: version, definition: definition, request: request))
    return outcome(["trial": [String: Any]()])
  }

  func controlListAutomations() -> Result<Any, ControlError> {
    outcome(["automations": [Any]()])
  }

  func controlSetAutomation(
    automationId: Int?, version: Int?, _ definition: [String: Any]
  ) -> Result<
    Any, ControlError
  > {
    setAutomations.append(FakeSetAutomation(automationId, version, definition))
    return outcome(["automation": ["automationId": automationId ?? 1]])
  }

  func controlListAutomationRuns(automationId: Int, nodeKey: String?, before: Int?, limit: Int?)
    -> Result<Any, ControlError>
  {
    runLists.append(FakeRunList(nodeKey: nodeKey, before: before, limit: limit))
    return outcome(["runs": [Any]()])
  }

  func controlRunAutomation(automationId: Int, nodeKey: String?) -> Result<Any, ControlError> {
    ranAutomations.append((automationId, nodeKey))
    return outcome(["ok": true])
  }

  func controlPauseAutomation(automationId: Int, nodeKey: String?, paused: Bool) -> Result<
    Any, ControlError
  > {
    pausedAutomations.append(
      FakePause(automationId: automationId, nodeKey: nodeKey, paused: paused))
    return outcome(["automation": ["automationId": automationId]])
  }

  func controlDeleteAutomation(automationId: Int) -> Result<Any, ControlError> {
    deletedAutomationIds.append(automationId)
    return outcome(["ok": true])
  }

  func controlListAutomationProposals(automationId: Int?) -> Result<Any, ControlError> {
    proposalLists.append(automationId)
    return outcome(["proposals": [Any]()])
  }

  func controlAutomationTrial(
    trialId: Int, wait: Bool, timeoutMs: Int,
    completion: @escaping (Result<Any, ControlError>) -> Void
  ) {
    readTrials.append(ReadTrial(trialId: trialId, wait: wait, timeoutMs: timeoutMs))
    completion(outcome(["trial": [String: Any]()]))
  }
}
