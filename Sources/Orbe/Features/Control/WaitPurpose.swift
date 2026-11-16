/// 待機の目的——何で起きるか・起きたときの応答の形・時間切れの形。`Connection` が待機ごとに
/// 1 つ持ち、配信された record を `matches` で選び `reply` で応答の本体へ写す。応答の `seq` は
/// `reply` ではなく `respond` が刻む——イベントで完結した応答は呼び出し側が record の seq を渡す。
enum WaitPurpose {
  /// `wait_for_event`。フィルタは全て省略可（省略＝全通し）。
  case event(tabId: Int?, kinds: Set<String>?, value: String?)
  /// `prompt_agent`。送信より後で最初に止まる agent_state（done / waiting / 消滅）で返す。
  case promptOutcome(tabId: Int)
  /// `spawn_agent` / `resume_agent`。起動より後の最初の idle で返す。
  case agentReady(tabId: Int, launch: AgentLaunch)

  /// `wait_for_event` のフィルタ（tabId / kinds / value）を `.event` へ解く。kinds は空でなく既知の語だけ（-32602）。
  static func eventFilter(tabId: Int?, kinds: [String]?, value: String?) throws(ControlError)
    -> WaitPurpose
  {
    if let kinds {
      guard !kinds.isEmpty else { throw ControlError(code: -32602, message: "invalid kinds") }
      if let unknown = kinds.first(where: { !ControlEvent.kinds.contains($0) }) {
        throw ControlError(code: -32602, message: "unknown kind: \(unknown)")
      }
    }
    return .event(tabId: tabId, kinds: kinds.map(Set.init), value: value)
  }

  func matches(_ event: ControlEvent) -> Bool {
    switch self {
    case .event(let tabId, let kinds, let value):
      if let tabId, tabId != event.tabId { return false }
      if let kinds, !kinds.contains(event.kind) { return false }
      if let value, value != event.value { return false }
      return true
    case .promptOutcome(let tabId):
      if tabId != event.tabId { return false }
      switch event {
      case .agentState(_, let state, _, _):
        return state == nil || state == "done" || state == "waiting"
      case .tabClosed:
        return true
      default:
        return false
      }
    case .agentReady(let tabId, _):
      if tabId != event.tabId { return false }
      switch event {
      case .agentState(_, "idle"?, _, _), .tabClosed:
        return true
      default:
        return false
      }
    }
  }

  /// `matches` した record への応答の本体。
  func reply(_ record: ControlEventRecord) -> Result<Any, ControlError> {
    switch (self, record.event) {
    case (.event, _):
      return .success(["event": record.toDict()])
    case (.promptOutcome, .agentState(_, _, let message, _)):
      var d: [String: Any] = [:]
      if let state = record.event.value { d["state"] = state }
      if let message { d["message"] = message }
      return .success(d)
    case (.promptOutcome, _):
      return .failure(ControlError(code: -32004, message: "tab closed"))
    case (.agentReady(_, let launch), .agentState(_, _, _, let sessionId)):
      var d = launch.toDict(ready: true)
      if let sessionId { d["agentSessionId"] = sessionId }
      return .success(d)
    case (.agentReady, _):
      return .failure(ControlError(code: -32000, message: "agent exited"))
    }
  }

  /// 時間切れの応答（`seq` は `respond` が応答時点の最新を刻む）。
  var timedOut: [String: Any] {
    switch self {
    case .event, .promptOutcome:
      return ["timedOut": true]
    case .agentReady(_, let launch):
      var d = launch.toDict(ready: false)
      d["timedOut"] = true
      return d
    }
  }
}
