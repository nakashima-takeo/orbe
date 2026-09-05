import Foundation

/// `spawn_agent` / `resume_agent` が起こした結果（domain）。wire の形は `toDict(ready:)` が組む。
struct AgentLaunch {
  let tabId: Int
  let workspaceId: Int
  let agent: AgentCLI

  /// `{tabId, workspaceId, agent:{command, path}, ready}`。`ready` はエージェントが
  /// 最初の idle を報告した（prompt を送れる）か。
  func toDict(ready: Bool) -> [String: Any] {
    [
      "tabId": tabId, "workspaceId": workspaceId,
      "agent": ["command": agent.command, "path": agent.path],
      "ready": ready,
    ]
  }
}

/// 待機を伴う動詞（prompt_agent / spawn_agent / resume_agent）。queue で param を検証し、main で
/// domain 操作を行い、queue で待機を張るか応答する二段 hop。`wait_for_event` だけは履歴の replay を
/// 伴うので `Connection.waitForEvent` が持つ。
extension ControlServer {
  /// `prompt_agent`: 送信より後で最初に止まる agent_state で返す。待機は送信の後に queue で張る
  /// だけでよい——送信が引き起こす遷移は FIFO により arm より後に積まれる（`emit` の順序保証）。
  func promptAgent(id: Any?, params: [String: Any], conn: Connection) {
    guard let tabId = params["tabId"] as? Int else {
      return conn.respond(
        id: id, result: .failure(ControlError(code: -32602, message: "missing tabId")))
    }
    guard let text = params["text"] as? String else {
      return conn.respond(
        id: id, result: .failure(ControlError(code: -32602, message: "missing text")))
    }
    guard let timeoutMs = WaitTimeout.parse(params, default: WaitTimeout.promptDefaultMs) else {
      return conn.respond(
        id: id, result: .failure(ControlError(code: -32602, message: "invalid timeoutMs")))
    }
    DispatchQueue.main.async {
      let refusal: ControlError?
      if let target = self.target {
        if let tab = target.controlResolveTab(tabId) {
          refusal = target.controlPromptAgent(tab: tab, text: text)
        } else {
          refusal = ControlError(code: -32004, message: "tab not found")
        }
      } else {
        refusal = ControlError(code: -32000, message: "no window")
      }
      self.queue.async {
        if let refusal {
          conn.respond(id: id, result: .failure(refusal))
        } else {
          conn.arm(id: id, purpose: .promptOutcome(tabId: tabId), timeoutMs: timeoutMs)
        }
      }
    }
  }

  /// `spawn_agent` / `resume_agent`: 起動後、idle を報告できる agent なら最初の idle まで待つ。
  /// 報告できない agent は即 `ready:false`。
  func launchAgent(
    id: Any?, params: [String: Any], conn: Connection,
    launch: @escaping (ControlTarget) -> Result<AgentLaunch, ControlError>
  ) {
    guard let timeoutMs = WaitTimeout.parse(params, default: WaitTimeout.launchDefaultMs) else {
      return conn.respond(
        id: id, result: .failure(ControlError(code: -32602, message: "invalid timeoutMs")))
    }
    DispatchQueue.main.async {
      let outcome =
        self.target.map(launch)
        ?? .failure(ControlError(code: -32000, message: "no window"))
      self.queue.async {
        switch outcome {
        case .failure(let error):
          conn.respond(id: id, result: .failure(error))
        case .success(let launched) where AgentCatalog.reportsIdleOnStart(launched.agent.command):
          conn.arm(
            id: id, purpose: .agentReady(tabId: launched.tabId, launch: launched),
            timeoutMs: timeoutMs)
        case .success(let launched):
          conn.respond(id: id, result: .success(launched.toDict(ready: false)))
        }
      }
    }
  }
}
