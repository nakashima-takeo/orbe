import Foundation

/// `spawn_agent` / `resume_agent` が起こした結果（domain）。wire の形は `toDict(ready:)` が組む。
struct AgentLaunch {
  let tabId: Int
  let workspaceId: UUID
  let agent: AgentCLI
  /// 再開する会話が既に生きているタブで開いていて、新しく起こさずそのタブを返したとき、今 prompt を送れるか
  /// （idle / done を報告しているか）。新しく起こしたなら nil（最初の idle を待つ）。
  var readyAsOpened: Bool?

  /// `{tabId, workspaceId, agent:{command, path}, ready}`。`ready` はエージェントが
  /// 最初の idle を報告した（prompt を送れる）か。
  func toDict(ready: Bool) -> [String: Any] {
    [
      "tabId": tabId, "workspaceId": workspaceId.uuidString,
      "agent": ["command": agent.command, "path": agent.path],
      "ready": ready,
    ]
  }
}

/// 待機を伴う動詞（wait_for_event / prompt_agent / spawn_agent / resume_agent）。queue で引数を読み、main で
/// domain 操作を行い、queue で待機を張るか応答する二段 hop。履歴の replay と待機は `Connection` が持つ。
extension ControlServer {
  /// `wait_for_event`: 宛先・フィルタ・期限は待機を張る**前**に確かめる。素通しすると待機はどちらかへ倒れ、
  /// どちらも呼び出し側から時間切れと区別できない——絞り込みが黙って消えれば「別タブ・別種の
  /// イベントで起きる」、一致しない語で張られれば「永遠に起きない」。
  func waitForEvent(id: Any?, params p: ControlParams, conn: Connection) {
    let purpose: WaitPurpose
    let after: Int?
    let timeoutMs: Int
    do throws(ControlError) {
      let tabId = try p.optionalInt("tabId")
      let kinds = try p.optionalStrings("kinds")
      let value = try p.optionalString("value")
      after = try p.optionalInt("after")
      timeoutMs = try WaitTimeout.parse(p, default: WaitTimeout.eventDefaultMs)
      purpose = try WaitPurpose.eventFilter(tabId: tabId, kinds: kinds, value: value)
      if let after, after < 0 { throw p.invalid("after") }
    } catch {
      return conn.respond(id: id, result: .failure(error))
    }
    conn.waitForEvent(id: id, purpose: purpose, after: after, timeoutMs: timeoutMs)
  }

  /// `prompt_agent`: 送信より後で最初に止まる agent_state で返す。待機は送信の後に queue で張る
  /// だけでよい——送信が引き起こす遷移は FIFO により arm より後に積まれる（`emit` の順序保証）。
  func promptAgent(id: Any?, params p: ControlParams, conn: Connection) {
    let tabId: Int
    let text: String
    let timeoutMs: Int
    do throws(ControlError) {
      tabId = try p.int("tabId")
      text = try p.string("text")
      timeoutMs = try WaitTimeout.parse(p, default: WaitTimeout.promptDefaultMs)
    } catch {
      return conn.respond(id: id, result: .failure(error))
    }
    DispatchQueue.main.async {
      let sent = self.onWindow { target -> Result<Void, ControlError> in
        guard let tab = target.controlResolveTab(tabId) else {
          return .failure(ControlError(code: -32004, message: "tab not found"))
        }
        if let refusal = target.controlPromptAgent(tab: tab, text: text) {
          return .failure(refusal)
        }
        return .success(())
      }
      self.queue.async {
        switch sent {
        case .failure(let refusal):
          conn.respond(id: id, result: .failure(refusal))
        case .success:
          conn.arm(id: id, purpose: .promptOutcome(tabId: tabId), timeoutMs: timeoutMs)
        }
      }
    }
  }

  /// `spawn_agent` / `resume_agent`: 起動後、idle を報告できる agent なら最初の idle まで待つ。
  /// 報告できない agent は即 `ready:false`。既に開いていた会話のタブを返したときは待たない。
  func launchAgent(
    id: Any?, conn: Connection, timeoutMs: Int,
    launch: @escaping (ControlTarget) -> Result<AgentLaunch, ControlError>
  ) {
    DispatchQueue.main.async {
      let outcome = self.onWindow(launch)
      self.queue.async {
        switch outcome {
        case .failure(let error):
          conn.respond(id: id, result: .failure(error))
        case .success(let launched) where launched.readyAsOpened != nil:
          conn.respond(id: id, result: .success(launched.toDict(ready: launched.readyAsOpened!)))
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
