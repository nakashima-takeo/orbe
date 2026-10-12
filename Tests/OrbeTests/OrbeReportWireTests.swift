import Darwin
import Foundation
import OrbeTestSupport
import XCTest

@testable import Orbe

/// `orbe-report` が制御ソケットへ書く**生の 1 行**を、テスト自前の AF_UNIX listener で受けて固定する。
///
/// なぜ実サーバ経由でなくこの形かというと、`orbe-report` は Orbe とモジュールを共有せず wire の語を
/// リテラルで持つため。実サーバへ流して振る舞いを観測する形だと、`orbe-report` 側だけ `tabId` を
/// `tab_id` に改名しても「報告が届かない」としか見えず、受け側が黙って無視した結果と区別できない。
/// 生の 1 行を読めば、どの語がどう欠けたかがその場で出る。
///
/// 壊れると何が起きるか: hook からの状態報告が無言で no-op に倒れる。エージェントの状態は
/// タブに一切現れなくなるが、どの実行体もエラーを出さない（`orbe-report` は接続できなくても
/// exit 0、サーバは知らない params を捨てるだけ）。
final class OrbeReportWireTests: OrbeTestCase {
  /// 報告元として名乗るタブ id（実タブは要らない——測るのは wire に載る語だけ）。
  private static let tabId = 7

  private var listenFD: Int32 = -1
  private var socketPath = ""

  override func setUpWithError() throws {
    // `sun_path` は 104 バイト上限。超えると bind が黙って落ち「接続が来ない」としか見えないので、
    // 長さ自体を先に測って失敗を可読にする。caseDir（`c<連番>` ぶん深い）ではなく隔離根の直下に置く。
    socketPath = TestScratch.root.appendingPathComponent("r.sock").path
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

  /// listener が 1 本の接続から受け取ったもの。
  private struct Served {
    var line: String
    /// 1 行を受けて少し置いた後も、接続の向こうのプロセスが取れた。Orbe は接続の向こうから報告者の
    /// プロセスグループをたどるので、受け取りが遅れても報告者が残っていなければならない。
    var peerHeld: Bool
    /// 応答の 1 行を書いてから報告者が閉じるまで（応答しなかったときは nil）。
    var closedAfterReply: TimeInterval?
  }

  /// 子が走っている間に背景で 1 接続を受け、1 行を読む。`reply` なら応答の 1 行を返す。どちらでも、本物の
  /// Orbe と同じく接続は自分からは畳まず、相手が閉じるまで保つ。`finish()` は子の終了後に呼ぶ——`connect` は子の終了より前に起きるので、
  /// その時点で接続が backlog に無ければ、接続しない経路だったと言い切れる。
  private final class OneShotServer {
    private let lock = NSLock()
    private var stopped = false
    private var served: Served?
    private let done = DispatchSemaphore(value: 0)

    init(listenFD: Int32, reply: Bool) {
      DispatchQueue.global().async { [self] in
        defer { done.signal() }
        while true {
          let last = lock.withLock { stopped }
          var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
          if poll(&pfd, 1, 50) > 0 { break }
          if last { return }
        }
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        // accept した fd は listener の O_NONBLOCK を継ぐ。blocking に戻して読む。
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        // 先に閉じた相手への応答で xctest ごと SIGPIPE で落ちないように。
        var noSigPipe: Int32 = 1
        _ = setsockopt(
          fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let line = Self.readLine(fd)
        usleep(200_000)
        let peerHeld = ProcessGroup.peer(of: fd).map { kill($0, 0) == 0 } ?? false
        var repliedAt: Date?
        if reply {
          let response = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8 + [0x0A])
          _ = response.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
          repliedAt = Date()
        }
        _ = Self.readLine(fd)  // 相手が閉じる（EOF）まで保つ
        let result = Served(
          line: String(data: line, encoding: .utf8) ?? "", peerHeld: peerHeld,
          closedAfterReply: repliedAt.map { Date().timeIntervalSince($0) })
        lock.withLock { served = result }
      }
    }

    func finish() -> Served? {
      lock.withLock { stopped = true }
      _ = done.wait(timeout: .now() + ControlProcess.processTimeout)
      return lock.withLock { served }
    }

    private static func readLine(_ fd: Int32) -> Data {
      var line = Data()
      var byte: UInt8 = 0
      while read(fd, &byte, 1) > 0, byte != 0x0A { line.append(byte) }
      return line
    }
  }

  /// `orbe-report <agent> <state>` を起こし、listener が受けたものを返す（接続が来なければ nil）。
  /// env は明示辞書のみ（親から継承しない）——継承すると開発者の実 `ORBE_SOCK` へ報告が飛ぶ。
  private func run(
    agent: String = "claude", state: String, stdin: String, dropping: [String] = [],
    reply: Bool = true, file: StaticString = #filePath, line: UInt = #line
  ) -> (served: Served?, elapsed: TimeInterval) {
    var env = [
      "PATH": "/usr/bin:/bin", "ORBE_TAB": String(Self.tabId), "ORBE_SOCK": socketPath,
    ]
    for key in dropping { env.removeValue(forKey: key) }
    let server = OneShotServer(listenFD: listenFD, reply: reply)
    let started = Date()
    let outcome = ControlProcess.run(
      ControlProcess.executable("orbe-report"), [agent, state], env: env, stdin: stdin,
      file: file, line: line)
    let elapsed = Date().timeIntervalSince(started)
    XCTAssertEqual(
      outcome.status, 0, "orbe-report は常に exit 0: \(outcome.stderr)", file: file, line: line)
    return (server.finish(), elapsed)
  }

  /// 応答する listener へ報告させ、受けた生の 1 行を返す（接続が来なければ nil）。
  private func report(
    agent: String = "claude", state: String, stdin: String, dropping: [String] = [],
    file: StaticString = #filePath, line: UInt = #line
  ) -> String? {
    run(agent: agent, state: state, stdin: stdin, dropping: dropping, file: file, line: line)
      .served?.line
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

  /// `report_agent` の params キー全集合。受け側（`ControlServer.resolvedTabHandler(for:)`）が読むキーと 1 対 1 で、
  /// `sessionId` が stdin の `session_id` からの抽出であることも同時に踏む。
  func testReportAgentWireCarriesFullParameterSet() throws {
    let raw = report(
      state: "waiting",
      stdin: #"{"session_id":"s-1","message":"許可しますか"}"#)
    let (method, params) = try request(raw)

    XCTAssertEqual(method, "report_agent", "hook の状態報告が乗る control メソッド名")
    XCTAssertEqual(
      Set(params.keys), ["tabId", "agent", "state", "sessionId", "message", "messageSource"],
      "params のキー集合（増減はどちらも受け側との断絶になる）")
    XCTAssertEqual(params["tabId"] as? Int, Self.tabId, "報告元は ORBE_TAB の値をそのまま載せる")
    XCTAssertEqual(params["agent"] as? String, "claude", "argv[1] が agent")
    XCTAssertEqual(params["state"] as? String, "waiting", "argv[2] が state")
    XCTAssertEqual(params["sessionId"] as? String, "s-1", "stdin の session_id が sessionId になる")
    XCTAssertEqual(params["message"] as? String, "許可しますか")
    XCTAssertEqual(
      params["messageSource"] as? String, "notification", "抽出した出所の語をそのまま載せる")
  }

  /// SessionEnd の `reason` は `reason` キーで運ぶ（受け側はセッションログの closed に載せる）。
  /// 持たない hook では載せない——`clear` の報告に理由が付くか付かないかは、この 1 語で決まる。
  func testSessionEndReasonRidesOnTheWireOnlyWhenPresent() throws {
    let ended = try request(
      report(state: "clear", stdin: #"{"session_id":"s-1","reason":"logout"}"#))
    XCTAssertEqual(ended.params["reason"] as? String, "logout", "stdin の reason が reason になる")

    let plain = try request(report(state: "clear", stdin: #"{"session_id":"s-1"}"#))
    XCTAssertNil(plain.params["reason"], "reason を持たない hook では載せない")
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
  /// ここが緩むと、サブエージェントの活動が親タブの状態を上書きして表示が暴れる。
  func testSubagentPayloadNeverConnects() throws {
    let raw = report(state: "done", stdin: #"{"session_id":"s-1","agent_id":"sub-1"}"#)
    XCTAssertNil(raw, "agent_id 入りの報告は socket へ接続しない")
  }

  /// Orbe 外（`ORBE_TAB` / `ORBE_SOCK` が無い端末）では接続しない。hook は Orbe を知らない
  /// セッションでも走るため、ここが no-op でないと無関係な端末から報告が飛ぶ。
  func testMissingTabOrSocketEnvNeverConnects() throws {
    XCTAssertNil(
      report(state: "working", stdin: "{}", dropping: ["ORBE_TAB"]),
      "ORBE_TAB が無ければ報告しない")
    XCTAssertNil(
      report(state: "working", stdin: "{}", dropping: ["ORBE_SOCK"]),
      "ORBE_SOCK が無ければ報告しない")
  }

  // MARK: - 接続の保ち方

  /// 報告者は Orbe の応答の 1 行まで接続を保ち、受けたら待たずに閉じる。保たないと、Orbe が受け取るのが
  /// 遅れたとき報告者のグループをたどれず、秘書のタブは会話へ貼ってよくならない。受けても閉じないと、Orbe は
  /// 接続を畳まないので、hook のたびに claude が待ちの上限まで止まる。
  func testReporterHoldsTheConnectionUntilTheReplyAndNoLonger() throws {
    let served = try XCTUnwrap(
      run(state: "idle", stdin: #"{"session_id":"s-1"}"#).served, "orbe-report が接続しない")
    XCTAssertTrue(served.peerHeld, "1 行を書いた後、応答を待たずに報告者が消えている")
    // 待ちの上限（2 秒）より十分短い。
    XCTAssertLessThan(
      try XCTUnwrap(served.closedAfterReply), 1, "応答を受けた後も、上限まで接続を保っている")
  }

  /// Orbe が受け取っても応答しないときは、上限で諦めて exit 0 で抜ける。hook は claude のターンを
  /// 同期で止めるので、ここが無限待ちになると Orbe の固まりが claude に伝わる。
  func testUnresponsiveOrbeReleasesTheHookWithinTheLimit() throws {
    let result = run(state: "idle", stdin: "{}", reply: false)
    XCTAssertNotNil(result.served, "orbe-report が接続しない")
    XCTAssertLessThan(result.elapsed, 5, "応答しない Orbe を上限を超えて待っている")
  }
}
