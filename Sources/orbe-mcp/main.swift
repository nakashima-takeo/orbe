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
