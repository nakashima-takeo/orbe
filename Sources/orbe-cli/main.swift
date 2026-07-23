import Darwin
import Foundation
import OrbePaths

// Orbe 自身を構成・操作する CLI（config / ws / pane / tab）。control.sock（改行区切り JSON-RPC 2.0）へ 1 リクエスト
// 1 接続で直接送る薄いクライアント。GUI 本体と同じ制御契約面を叩く。socket 解決は
// OrbePaths.controlSocketPath()（ORBE_STATE_DIR 直下・最優先 → ORBE_SOCK → Apple 規定の既定パス）に
// 一本化し、GUI 本体・mcp と同一実装を共有する。
// .app 同梱時は Contents/Resources/bin/orb へ改名され、ペイン PATH で bare `orb` に解決する。
// 引数パース・出力・サブコマンドは Support.swift / Commands.swift（Foundation + OrbePaths のみ・手書き）。

// MARK: - socket 解決（OrbePaths に委譲）

let socketPath: String = OrbePaths.controlSocketPath() ?? ""

// MARK: - control.sock クライアント（1 リクエスト 1 接続・同期）

enum RPCResult {
  case ok(Any)
  case rpcError(code: Int, message: String)
  case transport(String)  // 接続不可・framing 異常等（Orbe 未起動 or ペイン外）
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

func controlRequest(method: String, params: [String: Any]) -> RPCResult {
  guard let fd = connectControl() else {
    return .transport("Orbe not running (cannot connect \(socketPath))")
  }
  defer { close(fd) }

  let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
  guard var data = try? JSONSerialization.data(withJSONObject: req) else {
    return .transport("request encode failed")
  }
  data.append(0x0A)
  guard writeAll(fd, data) else { return .transport("write failed") }

  let buf = readResponseLine(fd)
  guard let obj = try? JSONSerialization.jsonObject(with: buf) as? [String: Any] else {
    return .transport("invalid response")
  }
  if let err = obj["error"] as? [String: Any] {
    return .rpcError(
      code: err["code"] as? Int ?? -32000, message: err["message"] as? String ?? "control error")
  }
  return .ok(obj["result"] ?? [:])
}

// MARK: - ディスパッチ

var args = Array(CommandLine.arguments.dropFirst())
// --json はどこに現れてもよい共通フラグ。先頭で抜き取り、残りを位置引数として扱う。
if let i = args.firstIndex(of: "--json") {
  wantJSON = true
  args.remove(at: i)
}

if args.isEmpty {
  print(topUsage)
  exit(2)
}

switch args[0] {
case "--help", "-h":
  print(topUsage)
  exit(0)
case "config":
  runConfig(Array(args.dropFirst()))
case "ws":
  runWorkspace(Array(args.dropFirst()))
case "pane":
  runPane(Array(args.dropFirst()))
case "tab":
  runTab(Array(args.dropFirst()))
default:
  usageDie("unknown command: \(args[0])")
}
