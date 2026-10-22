import Foundation

@testable import Orbe

/// `list_automation_runs` が届けたもの。
struct FakeRunList {
  let partKey: String?
  let before: Int?
  let limit: Int?
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

  func controlTryAutomation(automationId: Int, _ request: AutomationTrial.Request) -> Result<
    Any, ControlError
  > {
    triedAutomations.append((automationId, request))
    return outcome(["trial": [String: Any]()])
  }
}
