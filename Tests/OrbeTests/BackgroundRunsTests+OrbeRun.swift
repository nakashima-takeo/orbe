import XCTest

@testable import Orbe

/// 裏の agent に渡す Orbe の口の実経路——実行の係が claude に渡す MCP の定義どおりに同梱の `orbe-mcp` を起こすと、その回の
/// 道具だけが出て、呼び出しが制御 socket を通って実 `WindowController` の回の相手に届き、回が終われば断られる。
///
/// 壊れると何が起きるか: 札・道具・socket を運ぶ環境の名前や `run_tool` の綴りが Orbe 本体と `orbe-mcp` で食い違っても
/// コンパイルもほかのテストも通り、行を見る agent はどの回も入力を読めず結果も出せずに失敗し続ける。
extension BackgroundRunsTests {
  func testTheRunsMCPServerReachesItsRunThroughTheBundledBridge() throws {
    let control = try startControlProcess()
    let runSessions = control.target.automationRunner.runSessions
    let rows = ["a", "b"].map {
      AutomationPartRow(id: $0, text: #"{"id":"\#($0)"}"#, origin: nil, source: nil)
    }
    let session = AutomationRunSession(.process(rows, reachesJudge: false))
    let token = runSessions.open(session)
    try placeClaude(#"echo '{"type":"result","is_error":false,"result":"done"}'"#)
    let job = BackgroundJob.agent(
      BackgroundAgentCall(
        cli: "claude", model: "haiku", tools: [], prompt: "残す",
        orbe: BackgroundOrbeAccess(token: token, tools: session.tools.map(\.rawValue))))
    XCTAssertEqual(try run(runs(), job).ending, .exited(0))
    let server = try orbeServer(in: try receivedArguments())

    let replies = bridge(
      server,
      [
        ("tools/list", [:]),
        ("tools/call", ["name": "read_run_rows", "arguments": ["limit": 1]]),
        ("tools/call", ["name": "put_rows", "arguments": ["rows": [["id": "a"]]]]),
        ("tools/call", ["name": "read_run_rows", "arguments": ["offset": 1]]),
        ("tools/call", ["name": "put_rows", "arguments": ["rows": [["id": "a"]]]]),
      ])

    XCTAssertEqual(
      (replies[0]["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String },
      ["read_run_rows", "put_rows", "report_nothing"], "その回の道具だけを出す")
    XCTAssertEqual(texts(replies[1]).last, #"{"id":"a"}"#)
    XCTAssertEqual(replies[2]["isError"] as? Bool, true, "読み切る前の結果は断られる")
    XCTAssertEqual(texts(replies[3]).last, #"{"id":"b"}"#)
    XCTAssertEqual(replies[4]["isError"] as? Bool, false)
    XCTAssertEqual(session.outputs.count, 1, "受けた結果が回の相手に届く")

    runSessions.close(token)
    let ended = bridge(
      server, [("tools/call", ["name": "report_nothing", "arguments": ["why": "x"]])])
    XCTAssertEqual(ended.first?["isError"] as? Bool, true, "終わった回の札は断られる")
  }

  /// claude に渡した `--mcp-config` の Orbe の口のサーバー（起こすコマンドと環境）。環境は `${名前}` の参照で、claude が自分の
  /// 環境から展開するのと同じく、偽の claude が受けた環境から値を引く。
  private func orbeServer(in arguments: [String]) throws -> (command: String, env: [String: String])
  {
    let received = Dictionary(
      try String(contentsOf: bin.appendingPathComponent("env"), encoding: .utf8)
        .split(separator: "\n").compactMap { line -> (String, String)? in
          guard let equal = line.firstIndex(of: "=") else { return nil }
          return (String(line[..<equal]), String(line[line.index(after: equal)...]))
        }, uniquingKeysWith: { $1 })
    let index = try XCTUnwrap(arguments.firstIndex(of: "--mcp-config"), "\(arguments)")
    let config = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(arguments[index + 1].utf8)) as? [String: Any])
    let servers = try XCTUnwrap(config["mcpServers"] as? [String: [String: Any]])
    let server = try XCTUnwrap(servers[BackgroundOrbeAccess.server], "\(servers.keys)")
    let env = try XCTUnwrap(server["env"] as? [String: String])
    XCTAssertFalse(arguments.joined().contains(token(in: received)), "札はコマンド行に出さない")
    return (
      try XCTUnwrap(server["command"] as? String),
      try env.mapValues { reference in
        guard reference.hasPrefix("${"), reference.hasSuffix("}") else { return reference }
        return try XCTUnwrap(received[String(reference.dropFirst(2).dropLast())], reference)
      }
    )
  }

  private func token(in env: [String: String]) -> String {
    env["ORBE_RUN_TOKEN"] ?? "ORBE_RUN_TOKEN is missing"
  }

  /// 定義どおりに `orbe-mcp` を起こし（環境は定義の分と PATH だけ）、要求を順に流して各応答の `result` を返す。
  private func bridge(
    _ server: (command: String, env: [String: String]), _ requests: [(String, [String: Any])]
  ) -> [[String: Any]] {
    let lines = requests.enumerated().map { id, request in
      let message: [String: Any] = [
        "jsonrpc": "2.0", "id": id, "method": request.0, "params": request.1,
      ]
      return String(
        bytes: (try? JSONSerialization.data(withJSONObject: message)) ?? Data(), encoding: .utf8)
        ?? ""
    }
    let outcome = ControlProcess.run(
      URL(fileURLWithPath: server.command), [],
      env: server.env.merging(["PATH": "/usr/bin:/bin"]) { $1 },
      stdin: lines.joined(separator: "\n") + "\n")
    let replies = outcome.stdout.split(separator: "\n").compactMap {
      (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["result"]
        as? [String: Any]
    }
    XCTAssertEqual(replies.count, requests.count, outcome.stdout + outcome.stderr)
    return replies + Array(repeating: [:], count: max(0, requests.count - replies.count))
  }

  private func texts(_ result: [String: Any]) -> [String] {
    (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
  }
}
