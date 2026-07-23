import Darwin
import Foundation

// Orbe エージェント状態の報告 CLI。各 CLI の hook（シム orbe-agent-status.sh）から
// `orbe-report <agent> <state>` で呼ばれ、発信元ペインの状態を Orbe の制御ソケットへ
// JSON-RPC 1 行で送る。Orbe が注入する env（ORBE_PANE/ORBE_SOCK）が無ければ no-op。
// 接続は orbe-mcp の connectControl と同型（1 リクエスト 1 接続・同期）。

let env = ProcessInfo.processInfo.environment

// Orbe 内ペインの目印が無ければ Orbe 外＝no-op。
guard let paneIdStr = env["ORBE_PANE"], let paneId = Int(paneIdStr),
  let socketPath = env["ORBE_SOCK"], !socketPath.isEmpty
else { exit(0) }

let args = CommandLine.arguments
guard args.count >= 3 else { exit(0) }
let agent = args[1]
let state = args[2]
guard !agent.isEmpty, !state.isEmpty else { exit(0) }

// hook の stdin JSON は一度しか読めないため、パースは 1 回にまとめて
// session_id 抽出と background_tasks 判定（ReportLogic.swift）の両方に使う。
let hookObj = parseHookJSON(FileHandle.standardInput.readDataToEndOfFile())

func connectControl() -> Int32? {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { return nil }
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let pathBytes = socketPath.utf8CString
  guard pathBytes.count <= 104 else {
    close(fd)
    return nil
  }
  withUnsafeMutablePointer(to: &addr.sun_path) { raw in
    raw.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
      pathBytes.withUnsafeBufferPointer { src in
        dst.update(from: src.baseAddress!, count: src.count)
      }
    }
  }
  let len = socklen_t(MemoryLayout<sockaddr_un>.size)
  let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
  }
  guard connected == 0 else {
    close(fd)
    return nil
  }
  return fd
}

func writeAll(_ fd: Int32, _ data: Data) {
  data.withUnsafeBytes { raw in
    var sent = 0
    let base = raw.bindMemory(to: UInt8.self).baseAddress!
    while sent < data.count {
      let n = write(fd, base + sent, data.count - sent)
      if n <= 0 { return }
      sent += n
    }
  }
}

// resume 用 ID: stdin JSON に無ければ env ANTIGRAVITY_CONVERSATION_ID（非空のみ）。
let resumeId =
  sessionId(from: hookObj)
  ?? env["ANTIGRAVITY_CONVERSATION_ID"].flatMap { $0.isEmpty ? nil : $0 }
let reportedState = effectiveState(state, stdin: hookObj)
var params: [String: Any] = [
  "paneId": paneId, "agent": agent, "state": reportedState,
]
if let resumeId { params["sessionId"] = resumeId }
// waiting/done の文言（Notification message・質問文・最終応答）。無ければ載せない。
if let message = agentMessage(state: reportedState, stdin: hookObj) {
  params["message"] = message
}

// Orbe が動いていなければ接続できない＝no-op（exit 0）。
guard let fd = connectControl() else { exit(0) }
defer { close(fd) }

let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "report_agent", "params": params]
guard var data = try? JSONSerialization.data(withJSONObject: req) else { exit(0) }
data.append(0x0A)
writeAll(fd, data)
