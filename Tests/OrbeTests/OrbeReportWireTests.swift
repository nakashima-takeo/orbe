import Darwin
import Foundation
import XCTest

@testable import Orbe

/// `orbe-report` が制御ソケットへ書く**生の 1 行**を、テスト自前の AF_UNIX listener で受けて固定する。
///
/// なぜ実サーバ経由でなくこの形かというと、`orbe-report` は Orbe とモジュールを共有せず wire の語を
/// リテラルで持つため。実サーバへ流して振る舞いを観測する形だと、`orbe-report` 側だけ `paneId` を
/// `pane_id` に改名しても「報告が届かない」としか見えず、受け側が黙って無視した結果と区別できない。
/// 生の 1 行を読めば、どの語がどう欠けたかがその場で出る。
///
/// 壊れると何が起きるか: hook からの状態報告が無言で no-op に倒れる。エージェントの状態は
/// ペインに一切現れなくなるが、どの実行体もエラーを出さない（`orbe-report` は接続できなくても
/// exit 0、サーバは知らない params を捨てるだけ）。
final class OrbeReportWireTests: OrbeTestCase {
  /// 報告元として名乗るペイン id（実ペインは要らない——測るのは wire に載る語だけ）。
  private static let paneId = 7

  private var listenFD: Int32 = -1
  private var socketPath = ""

  override func setUpWithError() throws {
    // `sun_path` は 104 バイト上限。超えると bind が黙って落ち「接続が来ない」としか見えないので、
    // 長さ自体を先に測って失敗を可読にする。caseDir（`c<連番>` ぶん深い）ではなく隔離根の直下に置く。
    socketPath = TestIsolation.root.appendingPathComponent("r.sock").path
    XCTAssertLessThan(socketPath.utf8.count, 104, "listener の socket path が sun_path 上限を超える")

    unlink(socketPath)  // 隔離根は per-test で消えないため、前のテストの残骸を掃除してから bind する
    listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(listenFD, 0, "listener socket を作れない")
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = socketPath.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { raw in
      raw.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
        // 上限で切る。`XCTAssert` は記録するだけで実行を止めないため、境界を持たないと上限超過が
        // そのままスタック上の `sun_path` を壊す（本番の `ControlServer.openSocket` と同じ形）。
        bytes.withUnsafeBufferPointer { src in
          dst.update(from: src.baseAddress!, count: min(src.count, 104))
        }
      }
    }
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFD, $0, length) }
    }
    XCTAssertEqual(bound, 0, "listener を bind できない（errno=\(errno)）")
    XCTAssertEqual(listen(listenFD, 8), 0, "listener を listen できない（errno=\(errno)）")
    let flags = fcntl(listenFD, F_GETFL)
    XCTAssertTrue(flags >= 0 && fcntl(listenFD, F_SETFL, flags | O_NONBLOCK) >= 0, "O_NONBLOCK 失敗")
  }

  override func tearDownWithError() throws {
    if listenFD >= 0 { Darwin.close(listenFD) }
    listenFD = -1
    unlink(socketPath)
  }

  // MARK: - 駆動

  /// `orbe-report <agent> <state>` を起こし、listener が受けた生の 1 行を返す（接続が来なければ nil）。
  /// env は明示辞書のみ（親から継承しない）——継承すると開発者の実 `ORBE_SOCK` へ報告が飛ぶ。
  private func report(
    agent: String = "claude", state: String, stdin: String, dropping: [String] = [],
    file: StaticString = #filePath, line: UInt = #line
  ) -> String? {
    var env = [
      "PATH": "/usr/bin:/bin", "ORBE_PANE": String(Self.paneId), "ORBE_SOCK": socketPath,
    ]
    for key in dropping { env.removeValue(forKey: key) }
    let outcome = ControlProcess.run(
      ControlProcess.executable("orbe-report"), [agent, state], env: env, stdin: stdin,
      file: file, line: line)
    XCTAssertEqual(
      outcome.status, 0, "orbe-report は常に exit 0: \(outcome.stderr)", file: file, line: line)
    return acceptLine()
  }

  /// 届いた 1 行を読む。`connect` は子の終了より前に起きるので、報告する経路なら呼ばれた時点で
  /// 接続は backlog に在る＝待つ必要はない。短い猶予だけ置くのは、接続しない契約（サブエージェント・
  /// Orbe 外）の検証を「待ち時間ぶん遅いだけのテスト」にしないため。
  private func acceptLine(within seconds: TimeInterval = 0.5) -> String? {
    var fd: Int32 = -1
    _ = waitUntil(seconds) {
      fd = accept(listenFD, nil, nil)
      return fd >= 0
    }
    guard fd >= 0 else { return nil }
    defer { Darwin.close(fd) }
    // accept した fd は listener の O_NONBLOCK を継ぐ。子は終了済みなので blocking に戻して読み切る。
    let flags = fcntl(fd, F_GETFL)
    if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
    var line = Data()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) > 0 {
      if byte == 0x0A { break }
      line.append(byte)
    }
    return String(data: line, encoding: .utf8)
  }

  /// 生の 1 行を JSON-RPC リクエストとして解く。
  private func request(
    _ raw: String?, file: StaticString = #filePath, line: UInt = #line
  ) throws -> (method: String, params: [String: Any]) {
    let text = try XCTUnwrap(raw, "orbe-report が listener へ 1 行も書かない", file: file, line: line)
    let data = try XCTUnwrap(text.data(using: .utf8), file: file, line: line)
    let obj = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any],
      "書かれた行が JSON オブジェクトでない: \(text)", file: file, line: line)
    return (
      try XCTUnwrap(obj["method"] as? String, "method が無い: \(text)", file: file, line: line),
      try XCTUnwrap(obj["params"] as? [String: Any], "params が無い: \(text)", file: file, line: line)
    )
  }

  // MARK: - 語の固定

  /// `report_agent` の params キー全集合。受け側（`ControlServer.runWindowed`）が読むキーと 1 対 1 で、
  /// `sessionId` が stdin の `session_id` からの抽出であることも同時に踏む。
  func testReportAgentWireCarriesFullParameterSet() throws {
    let raw = report(
      state: "waiting",
      stdin: #"{"session_id":"s-1","message":"許可しますか"}"#)
    let (method, params) = try request(raw)

    XCTAssertEqual(method, "report_agent", "hook の状態報告が乗る control メソッド名")
    XCTAssertEqual(
      Set(params.keys), ["paneId", "agent", "state", "sessionId", "message", "messageSource"],
      "params のキー集合（増減はどちらも受け側との断絶になる）")
    XCTAssertEqual(params["paneId"] as? Int, Self.paneId, "報告元は ORBE_PANE の値をそのまま載せる")
    XCTAssertEqual(params["agent"] as? String, "claude", "argv[1] が agent")
    XCTAssertEqual(params["state"] as? String, "waiting", "argv[2] が state")
    XCTAssertEqual(params["sessionId"] as? String, "s-1", "stdin の session_id が sessionId になる")
    XCTAssertEqual(params["message"] as? String, "許可しますか")
  }

  /// `messageSource` の値は受け側 `AgentMessage` のリテラルと 1 対 1。通知由来なら `notification`、
  /// ツール由来（`AskUserQuestion` の質問文）なら `tool`。
  func testMessageSourceLiteralsMatchReceiverVocabulary() throws {
    let notification = try request(
      report(state: "waiting", stdin: #"{"message":"許可しますか"}"#))
    XCTAssertEqual(
      notification.params["messageSource"] as? String, "notification", "Notification の message 由来")

    let tool = try request(
      report(
        state: "waiting",
        stdin: #"{"tool_input":{"questions":[{"question":"どちらにしますか"}]}}"#))
    XCTAssertEqual(tool.params["messageSource"] as? String, "tool", "PreToolUse の質問文由来")
    XCTAssertEqual(tool.params["message"] as? String, "どちらにしますか", "先頭の質問文を載せる")
  }

  /// `done` の裏で background_tasks が走っていれば、wire に載る `state` は `working` へ読み替わる
  /// （読み替えは `orbe-report` 側で完結し、サーバは読み替え後の値しか見ない）。
  func testRunningBackgroundTasksRewriteDoneToWorkingOnTheWire() throws {
    let raw = report(
      state: "done",
      stdin: #"{"background_tasks":[{"status":"running"}],"last_assistant_message":"完了"}"#)
    let (_, params) = try request(raw)

    XCTAssertEqual(params["state"] as? String, "working", "走っている裏タスクがあれば done は working")
    XCTAssertNil(params["message"], "working は文言を持たない（done 用の文言は載せない）")
  }

  /// サブエージェントの hook payload（`agent_id` 入り）は接続すら張らずに落ちる。
  /// ここが緩むと、サブエージェントの活動が親ペインの状態を上書きして表示が暴れる。
  func testSubagentPayloadNeverConnects() throws {
    let raw = report(state: "done", stdin: #"{"session_id":"s-1","agent_id":"sub-1"}"#)
    XCTAssertNil(raw, "agent_id 入りの報告は socket へ接続しない")
  }

  /// Orbe 外（`ORBE_PANE` / `ORBE_SOCK` が無い端末）では接続しない。hook は Orbe を知らない
  /// セッションでも走るため、ここが no-op でないと無関係な端末から報告が飛ぶ。
  func testMissingPaneOrSocketEnvNeverConnects() throws {
    XCTAssertNil(
      report(state: "working", stdin: "{}", dropping: ["ORBE_PANE"]),
      "ORBE_PANE が無ければ報告しない")
    XCTAssertNil(
      report(state: "working", stdin: "{}", dropping: ["ORBE_SOCK"]),
      "ORBE_SOCK が無ければ報告しない")
  }
}
