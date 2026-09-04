/// 待機の目的——何で起きるか・起きたときの応答の形・時間切れの形。`Connection` が待機ごとに
/// 1 つ持ち、配信された record を `matches` で選び `reply` で応答へ写す。イベントで完結する
/// 応答の `seq` は**そのイベントの seq**（応答時点の最新ではない）——履歴から replay して返した
/// 場合に、そのイベントと応答の間のイベントを次の `after` で取りこぼさないため。
enum WaitPurpose {
  /// `wait_for_event`。フィルタは全て省略可（省略＝全通し）。
  case event(paneId: Int?, kinds: Set<String>?, value: String?)
  /// `prompt_agent`。送信より後で最初に止まる agent_state（done / waiting / 消滅）で返す。
  case promptOutcome(paneId: Int)
  /// `spawn_agent` / `resume_agent`。起動より後の最初の idle で返す。
  case agentReady(paneId: Int, launch: AgentLaunch)

  /// `wait_for_event` の params（paneId / kinds / value）を `.event` へ解く。失敗は -32602。
  static func eventFilter(_ params: [String: Any]) -> Result<WaitPurpose, ControlError> {
    func invalid(_ message: String) -> Result<WaitPurpose, ControlError> {
      .failure(ControlError(code: -32602, message: message))
    }
    var paneId: Int?
    if let raw = params["paneId"] {
      guard let pid = raw as? Int else { return invalid("invalid paneId") }
      paneId = pid
    }
    var kinds: Set<String>?
    if let raw = params["kinds"] {
      guard let list = raw as? [String], !list.isEmpty else { return invalid("invalid kinds") }
      if let unknown = list.first(where: { !ControlEvent.kinds.contains($0) }) {
        return invalid("unknown kind: \(unknown)")
      }
      kinds = Set(list)
    }
    var value: String?
    if let raw = params["value"] {
      guard let v = raw as? String else { return invalid("invalid value") }
      value = v
    }
    return .success(.event(paneId: paneId, kinds: kinds, value: value))
  }

  func matches(_ event: ControlEvent) -> Bool {
    switch self {
    case .event(let paneId, let kinds, let value):
      if let paneId, paneId != event.paneId { return false }
      if let kinds, !kinds.contains(event.kind) { return false }
      if let value, value != event.value { return false }
      return true
    case .promptOutcome(let paneId):
      switch event {
      case .agentState(paneId, let state, _, _):
        return state == nil || state == "done" || state == "waiting"
      case .paneClosed(paneId):
        return true
      default:
        return false
      }
    case .agentReady(let paneId, _):
      switch event {
      case .agentState(paneId, "idle"?, _, _), .paneClosed(paneId):
        return true
      default:
        return false
      }
    }
  }

  /// `matches` した record への応答。
  func reply(_ record: ControlEventRecord) -> Result<Any, ControlError> {
    switch (self, record.event) {
    case (.event, _):
      return .success(["event": record.toDict(), "seq": record.seq])
    case (.promptOutcome, .agentState(_, let state, let message, _)):
      var d: [String: Any] = ["state": state ?? "clear", "seq": record.seq]
      if let message { d["message"] = message }
      return .success(d)
    case (.promptOutcome, _):
      return .failure(ControlError(code: -32004, message: "pane closed"))
    case (.agentReady(_, let launch), .agentState(_, _, _, let sessionId)):
      var d = launch.toDict(ready: true)
      if let sessionId { d["agentSessionId"] = sessionId }
      d["seq"] = record.seq
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
