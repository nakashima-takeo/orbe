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
}
