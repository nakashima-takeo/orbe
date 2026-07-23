import Darwin
import Foundation
import OrbePaths

// Orbe 制御チャネルの MCP ブリッジ。MCP(stdio・改行区切り JSON-RPC 2.0) を喋り、
// tools/call を Orbe.app の control.sock（同じく JSON-RPC）へそのまま転送する薄い層。
// ツール定義をここに置くことで、Orbe 本体を再ビルド/再起動せずツールを反復できる。

// control.sock の解決は OrbePaths.controlSocketPath() に一本化（GUI 本体・cli と同一実装）。
// ORBE_STATE_DIR 直下・最優先 → ORBE_SOCK → Apple 規定の既定パス。
let socketPath: String = OrbePaths.controlSocketPath() ?? ""

// MARK: - control.sock クライアント（1 リクエスト 1 接続・同期）

enum ControlResult {
  case ok(Any)
  case err(String)
}

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

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
  data.withUnsafeBytes { raw -> Bool in
    var sent = 0
    let base = raw.bindMemory(to: UInt8.self).baseAddress!
    while sent < data.count {
      let n = write(fd, base + sent, data.count - sent)
      if n <= 0 { return false }
      sent += n
    }
    return true
  }
}

/// 改行終端の 1 行を読む。
func readResponseLine(_ fd: Int32) -> Data {
  var buf = Data()
  var byte: UInt8 = 0
  while read(fd, &byte, 1) > 0 {
    if byte == 0x0A { break }
    buf.append(byte)
  }
  return buf
}

func controlRequest(method: String, params: [String: Any]) -> ControlResult {
  guard let fd = connectControl() else {
    return .err("Orbe not running (cannot connect \(socketPath))")
  }
  defer { close(fd) }

  let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
  guard var data = try? JSONSerialization.data(withJSONObject: req) else {
    return .err("encode failed")
  }
  data.append(0x0A)
  guard writeAll(fd, data) else { return .err("write failed") }

  let buf = readResponseLine(fd)
  guard let obj = try? JSONSerialization.jsonObject(with: buf) as? [String: Any] else {
    return .err("invalid response")
  }
  if let err = obj["error"] as? [String: Any] {
    return .err(err["message"] as? String ?? "control error")
  }
  return .ok(obj["result"] ?? [:])
}

// MARK: - ツール定義（v1: 最小コア + wait_for_event）

func obj(_ pairs: [(String, Any)]) -> [String: Any] { Dictionary(uniqueKeysWithValues: pairs) }
func strProp(_ desc: String) -> [String: Any] { ["type": "string", "description": desc] }
func intProp(_ desc: String) -> [String: Any] { ["type": "integer", "description": desc] }
func boolProp(_ desc: String) -> [String: Any] { ["type": "boolean", "description": desc] }

func schema(_ props: [String: Any], required: [String] = []) -> [String: Any] {
  ["type": "object", "properties": props, "required": required]
}

let tools: [[String: Any]] = [
  obj([
    ("name", "list_workspaces"),
    (
      "description",
      "Orbe の全 workspace を列挙する（id・名前・root path・タブ数・アクティブか・休眠 agent 数 dormantAgentCount）。"
    ),
    ("inputSchema", schema([:])),
  ]),
  obj([
    ("name", "list_panes"),
    (
      "description",
      "全ペインを列挙する。paneId（操作の宛先）・所属 workspace/tab・タイトル・cwd・エージェント状態・フォーカスの有無を返す。"
    ),
    ("inputSchema", schema([:])),
  ]),
  obj([
    ("name", "list_agents"),
    (
      "description",
      "検出済みのエージェント CLI（claude / codex / agy）を列挙する。各要素は command と解決済み絶対 path。"
        + "spawn の command に渡す候補源。検出未完了なら空配列を返す。"
    ),
    ("inputSchema", schema([:])),
  ]),
  obj([
    ("name", "get_pane_text"),
    ("description", "ペインの画面テキストを平文で取得する。scrollback=true で履歴全体、false で可視範囲のみ。"),
    (
      "inputSchema",
      schema(
        ["paneId": intProp("対象ペイン ID"), "scrollback": boolProp("履歴全体を含めるか（既定 false）")],
        required: ["paneId"])
    ),
  ]),
  obj([
    ("name", "send_text"),
    (
      "description",
      "ペインへテキストをペースト相当で送る。bracketed paste 下では改行を含めても"
        + "自己実行せずプロンプトに留まる。コマンドを実行するには送信後に send_key で enter を送る。"
    ),
    (
      "inputSchema",
      schema(
        ["paneId": intProp("対象ペイン ID"), "text": strProp("送るテキスト")],
        required: ["paneId", "text"])
    ),
  ]),
  obj([
    ("name", "send_key"),
    (
      "description",
      "ペインへ名前付きキーを送る。例: enter / tab / escape / up / down / left / right / "
        + "home / end / pageup / pagedown / backspace / 'ctrl+c' / 'ctrl+l'。"
    ),
    (
      "inputSchema",
      schema(
        ["paneId": intProp("対象ペイン ID"), "key": strProp("キー名（修飾は + 連結。例 'ctrl+c'）")],
        required: ["paneId", "key"])
    ),
  ]),
  obj([
    ("name", "spawn"),
    ("description", "新しいタブを開く。command 省略時はシェル、指定時はそのコマンドを直接起動。戻り値は新ペイン ID。"),
    (
      "inputSchema",
      schema([
        "workspaceId": intProp("開く workspace（省略時アクティブ）"),
        "cwd": strProp("作業ディレクトリ（省略時アクティブペイン由来）"),
        "command": strProp("シェルの代わりに起動するコマンド（絶対パス推奨）"),
      ])
    ),
  ]),
  obj([
    ("name", "activate_workspace"),
    (
      "description",
      "休眠/背景 workspace をアクティブ化して全タブを mount する。戻り値は activeWorkspaceId と mount された"
        + "ペインの paneId 群。0タブ WS は空状態を表示（シェルは自動起動せず paneIds は空配列）。既にアクティブなら no-op で成功。"
    ),
    (
      "inputSchema",
      schema(["workspaceId": intProp("アクティブにする workspace の id")], required: ["workspaceId"])
    ),
  ]),
  obj([
    ("name", "wait_for_event"),
    (
      "description",
      "状態変化イベントを待つ（長ポーリング）。扱える kind: agent_state / pane_title / pwd / "
        + "pane_closed（libghostty が host に出す OSC シグナル）。生のシェル出力は待てない"
        + "（その用途は get_pane_text をポーリング）。タイムアウトすると timedOut:true を返す。"
    ),
    (
      "inputSchema",
      schema([
        "paneId": intProp("このペインのイベントだけ待つ（省略時は全ペイン）"),
        "kinds": [
          "type": "array", "items": ["type": "string"],
          "description": "待つ kind の集合（省略時は全種）",
        ],
        "timeoutMs": intProp("タイムアウト ミリ秒（既定 30000）"),
      ])
    ),
  ]),
]

let toolNames = Set(tools.compactMap { $0["name"] as? String })

// MARK: - MCP メッセージ処理

func send(_ obj: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: obj),
    let line = String(data: data, encoding: .utf8)
  else { return }
  print(line)
  fflush(stdout)
}

func reply(id: Any, result: [String: Any]) {
  send(["jsonrpc": "2.0", "id": id, "result": result])
}

func replyError(id: Any, code: Int, message: String) {
  send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func handle(_ message: [String: Any]) {
  let method = message["method"] as? String ?? ""
  let id = message["id"]  // 通知（id 無し）には応答しない

  switch method {
  case "initialize":
    guard let id else { return }
    let version =
      (message["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-06-18"
    reply(
      id: id,
      result: [
        "protocolVersion": version,
        "capabilities": ["tools": [String: Any]()],
        "serverInfo": ["name": "orbe", "version": "0.1.0"],
      ])

  case "tools/list":
    guard let id else { return }
    reply(id: id, result: ["tools": tools])

  case "tools/call":
    guard let id else { return }
    let params = message["params"] as? [String: Any] ?? [:]
    guard let name = params["name"] as? String, toolNames.contains(name) else {
      replyError(id: id, code: -32602, message: "unknown tool")
      return
    }
    let args = params["arguments"] as? [String: Any] ?? [:]
    switch controlRequest(method: name, params: args) {
    case .ok(let value):
      let text = jsonText(value)
      reply(id: id, result: ["content": [["type": "text", "text": text]]])
    case .err(let err):
      reply(
        id: id,
        result: ["content": [["type": "text", "text": err]], "isError": true])
    }

  case "ping":
    if let id { reply(id: id, result: [:]) }

  default:
    // notifications/initialized 等は通知なので無視。未知の request にはエラーを返す。
    if let id { replyError(id: id, code: -32601, message: "method not found: \(method)") }
  }
}

func jsonText(_ value: Any) -> String {
  guard JSONSerialization.isValidJSONObject(value),
    let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
    let s = String(data: data, encoding: .utf8)
  else { return String(describing: value) }
  return s
}

// stdin を 1 行ずつ読んで処理する。
while let line = readLine(strippingNewline: true) {
  if line.isEmpty { continue }
  guard let data = line.data(using: .utf8),
    let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { continue }
  handle(message)
}
