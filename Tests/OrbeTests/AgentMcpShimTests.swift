import OrbeTestSupport
import XCTest

/// MCP シム（`app/agent-plugin/.../mcp/orbe-mcp.sh`）と空サーバー（`mcp/empty-server.pl`）を実 `/bin/sh`・
/// 実 perl で機械検証する。CLI は有効なプラグインの MCP サーバーを全セッションで起こすので、シムは
/// 自分のチャネルの Orbe のタブでだけタブの `orbe-mcp` へつなぎ、それ以外ではツール 0 個のサーバーとして
/// 正常に応答する。チャネルの規則は状態追跡のシム（`AgentShimChannelGateTests`）と同じ。
///
/// 壊れると何が起きるか: dev のタブの agent が release の Orbe を操作する（その逆も）。あるいは Orbe の外の
/// claude / codex が毎セッション接続失敗を警告する。
final class AgentMcpShimTests: OrbeTestCase {
  /// リポジトリ実体のプラグインルート。このファイル: <repo>/Tests/OrbeTests/...swift → 3 階層上が repo root。
  private static let sourcePluginRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // OrbeTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root
    .appendingPathComponent("app/agent-plugin/plugins/orbe-agent")

  private static let delegatedMarker = "delegated"

  private var work: URL!
  private var pluginRoot: URL!
  private var mcpBin: URL!  // stdin を記録し、目印の 1 行を返す fake orbe-mcp
  private var mcpLog: URL!

  override func setUpWithError() throws {
    work = TestScratch.caseDir.appendingPathComponent("AgentMcpShimTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    pluginRoot = work.appendingPathComponent("plugin")
    try FileManager.default.copyItem(at: Self.sourcePluginRoot, to: pluginRoot)
    mcpLog = work.appendingPathComponent("mcp.log")
    mcpBin = work.appendingPathComponent("orbe-mcp")
    let script = """
      #!/bin/sh
      cat > "\(mcpLog.path)"
      echo \(Self.delegatedMarker)
      """
    try Data(script.utf8).write(to: mcpBin)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mcpBin.path)
  }

  private func writeChannel(_ bundleId: String) throws {
    try Data("\(bundleId)\n".utf8).write(to: pluginRoot.appendingPathComponent("channel"))
  }

  /// シムを実 `/bin/sh` で起こし、stdout の行を返す。`relative` は cwd＝プラグインルートからの相対呼び
  /// （agy・codex の形）。絶対パス呼び（claude）は別ディレクトリから起こし、`$0` 相対の解決を突く。
  private func runShim(
    bundleId: String?, withMcpBin: Bool = true, relative: Bool = false, stdin: [String]
  ) -> [String] {
    var env = ["PATH": "/usr/bin:/bin"]
    if withMcpBin { env["ORBE_MCP_BIN"] = mcpBin.path }
    if let bundleId { env["ORBE_BUNDLE_ID"] = bundleId }
    let shim =
      relative ? "./mcp/orbe-mcp.sh" : pluginRoot.appendingPathComponent("mcp/orbe-mcp.sh").path
    let outcome = ControlProcess.run(
      URL(fileURLWithPath: "/bin/sh"), [shim], env: env,
      stdin: stdin.joined(separator: "\n") + "\n",
      cwd: relative ? pluginRoot.path : work.path)
    XCTAssertEqual(outcome.status, 0, outcome.stderr)
    return outcome.stdout.split(separator: "\n").map(String.init)
  }

  private let toolsList = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#

  private func assertDelegated(_ out: [String], file: StaticString = #filePath, line: UInt = #line)
  {
    XCTAssertEqual(out, [Self.delegatedMarker], file: file, line: line)
    XCTAssertEqual(
      try? String(contentsOf: mcpLog, encoding: .utf8), toolsList + "\n", "stdin がそのまま渡る",
      file: file, line: line)
  }

  private func assertEmptyServer(
    _ out: [String], file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(
      out, [#"{"id":1,"jsonrpc":"2.0","result":{"tools":[]}}"#], file: file, line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: mcpLog.path), "orbe-mcp は起こさない", file: file, line: line
    )
  }

  func testMatchingChannelExecsTheTabsBridge() throws {
    try writeChannel("dev.orbe.app.dev")
    assertDelegated(runShim(bundleId: "dev.orbe.app.dev", stdin: [toolsList]))
  }

  func testMatchingChannelExecsTheTabsBridgeOnRelativeInvocation() throws {
    try writeChannel("dev.orbe.app.dev")
    assertDelegated(runShim(bundleId: "dev.orbe.app.dev", relative: true, stdin: [toolsList]))
  }

  /// 別チャネルの Orbe のタブでは、そのタブの Orbe につながない。
  func testMismatchedChannelIsEmptyServer() throws {
    try writeChannel("dev.orbe.app")
    assertEmptyServer(runShim(bundleId: "dev.orbe.app.dev", stdin: [toolsList]))
    assertEmptyServer(runShim(bundleId: "dev.orbe.app.dev", relative: true, stdin: [toolsList]))
  }

  /// Orbe の外（`ORBE_MCP_BIN` 無し）。
  func testOutsideOrbeIsEmptyServer() throws {
    try writeChannel("dev.orbe.app.dev")
    assertEmptyServer(runShim(bundleId: nil, withMcpBin: false, stdin: [toolsList]))
  }

  /// 判定材料の片方が欠けたら通す（状態追跡のシムと同じ規則）。
  func testMissingChannelOrBundleIdExecsTheBridge() throws {
    assertDelegated(runShim(bundleId: "dev.orbe.app.dev", stdin: [toolsList]))
    try FileManager.default.removeItem(at: mcpLog)
    try writeChannel("dev.orbe.app.dev")
    assertDelegated(runShim(bundleId: nil, stdin: [toolsList]))
  }

  /// 空サーバーは MCP の握手に応え、ツールを名乗らない。id の型を保ち、通知と読めない行には応えない。
  func testEmptyServerAnswersHandshakeWithoutTools() throws {
    let out = runShim(
      bundleId: nil, withMcpBin: false,
      stdin: [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        "not json",
        #"{"jsonrpc":"2.0","id":"s","method":"tools/list"}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_tasks"}}"#,
      ])
    let replies = out.compactMap {
      try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
    XCTAssertEqual(replies.count, 4, "\(out)")
    guard replies.count == 4 else { return }

    let initialize = replies[0]["result"] as? [String: Any]
    XCTAssertEqual(initialize?["protocolVersion"] as? String, "2025-03-26", "要求の版をそのまま返す")
    XCTAssertEqual((initialize?["capabilities"] as? [String: Any])?.isEmpty, true, "tools を名乗らない")
    XCTAssertEqual(replies[1]["id"] as? String, "s")
    XCTAssertEqual(((replies[1]["result"] as? [String: Any])?["tools"] as? [Any])?.isEmpty, true)
    XCTAssertEqual(replies[2]["id"] as? Int, 3)
    XCTAssertNotNil(replies[2]["result"])
    XCTAssertEqual((replies[3]["error"] as? [String: Any])?["code"] as? Int, -32601)
  }
}
