import Foundation
import XCTest

@testable import Orbe

/// `prompt_agent`（テキスト＋Enter を送り、その送信より後で最初に止まる agent_state で返す）の
/// wire 契約を固定する。送信の中身（busy / 未 mount の判定・PTY への書込み）は target の領分で、
/// 実 `WindowController` 側は L2 / L4 が測る。ここが見るのは queue → main → queue の二段 hop と、
/// 何で起きて何を返すか。
///
/// 壊れると何が起きるか: `orb agent prompt` と MCP の `prompt_agent` が「送ったのに返らない」か
/// 「送る前の状態で返る」のどちらかに倒れる。止まる状態の集合が広がれば `working` で即返って
/// 応答を読めず、狭まれば `waiting` を待ち続けて時間切れになる。送信直後に済んだ遷移を落とせば、
/// `orb pane send` → `orb wait` の隙間の取りこぼしがそのまま戻る。
extension ControlWireTests {
  private func result(_ response: [String: Any]?) -> [String: Any]? {
    response?["result"] as? [String: Any]
  }

  private func errorMessage(_ response: [String: Any]?) -> String? {
    (response?["error"] as? [String: Any])?["message"] as? String
  }

  /// `prompt_agent` を送り、main 往復と待機の登録が済んだことを barrier で確定させる。
  private func prompt(
    _ wire: ControlWire, id: Int, paneId: Int, text: String = "hello", extra: [String: Any] = [:]
  ) {
    var params: [String: Any] = ["paneId": paneId, "text": text]
    for (key, value) in extra { params[key] = value }
    wire.send(["jsonrpc": "2.0", "id": id, "method": "prompt_agent", "params": params])
    wire.barrier()
  }

  private func state(_ paneId: Int, _ state: String?, message: String? = nil) -> ControlEvent {
    .agentState(paneId: paneId, state: state, message: message, sessionId: nil)
  }

  // MARK: - 送って、止まるまで待つ

  /// テキストが target へ届き、`working` では起きず、`done` で `{state, message, seq}` を返す。
  func testPromptDeliversTextAndAnswersWithTheFirstStoppingState() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let pane = fake.paneId

    prompt(wire, id: 1, paneId: pane, text: "explain this")
    XCTAssertEqual(fake.prompts.last?.paneId, pane, "paneId が名前どおり target へ届く")
    XCTAssertEqual(fake.prompts.last?.text, "explain this", "text が名前どおり target へ届く")

    ControlServer.shared.emit(state(pane, "working"))
    wire.barrier()  // working は「止まった」ではない

    ControlServer.shared.emit(state(pane, "done", message: "here is the answer"))
    let response = wire.nextResponse()
    XCTAssertEqual(response?["id"] as? Int, 1, "prompt_agent を送った id で応答が返る")
    XCTAssertEqual(result(response)?["state"] as? String, "done")
    XCTAssertEqual(result(response)?["message"] as? String, "here is the answer", "done の文言は最終応答")
    XCTAssertEqual(
      result(response)?["seq"] as? Int, latestSeq(wire, id: 2), "seq は返したイベントの seq")
  }

  /// `waiting` は `state: waiting`（質問文つき）、報告の消滅（SessionEnd）は `state: clear` で返る。
  func testPromptAnswersWaitingAndClear() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let pane = fake.paneId

    prompt(wire, id: 1, paneId: pane)
    ControlServer.shared.emit(state(pane, "waiting", message: "続けますか"))
    let waiting = result(wire.nextResponse())
    XCTAssertEqual(waiting?["state"] as? String, "waiting")
    XCTAssertEqual(waiting?["message"] as? String, "続けますか", "waiting の文言は質問文")

    prompt(wire, id: 2, paneId: pane)
    ControlServer.shared.emit(state(pane, nil))
    let clear = result(wire.nextResponse())
    XCTAssertEqual(clear?["state"] as? String, "clear", "報告の消滅は clear（value 無しを state に写す）")
  }

  /// 文言の無い遷移では `message` キー自体を持たない（null を置かない）。
  func testPromptOmitsMessageWhenTheReportCarriedNone() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    prompt(wire, id: 1, paneId: fake.paneId)
    ControlServer.shared.emit(state(fake.paneId, "done"))
    let done = result(wire.nextResponse())

    XCTAssertEqual(done?["state"] as? String, "done", "前提: done で返っている")
    XCTAssertNil(done?["message"], "文言が無ければ message キーを落とす")
  }

  /// 送信直後に済んだ遷移を取りこぼさない。遷移は送信の同じ main ターンから hop してくる（hook →
  /// `report_agent` → main の最短形）ので、別の要求として `wait_for_event` を送っていては間に合わない
  /// ——`orb pane send` → `orb wait` の隙間そのもの。
  func testTransitionRightAfterSendingIsNotMissed() {
    let fake = FakeControlTarget()
    let pane = fake.paneId
    fake.promptSideEffect = {
      DispatchQueue.main.async {
        ControlServer.shared.emit(self.state(pane, "done", message: "fast"))
      }
    }
    let wire = startWire(target: fake)

    let response = wire.request(
      id: 1, method: "prompt_agent", params: ["paneId": pane, "text": "x"])

    XCTAssertEqual(result(response)?["state"] as? String, "done", "送信直後の done で返る（時間切れにならない）")
    XCTAssertEqual(result(response)?["message"] as? String, "fast")
  }

  /// 別ペインの停止では起きない。
  func testPromptIgnoresOtherPanes() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    prompt(wire, id: 1, paneId: fake.paneId)
    ControlServer.shared.emit(state(fake.paneId + 1, "done"))
    wire.barrier()
  }

  // MARK: - 打ち切り

  /// 待機中にそのペインが閉じたら -32004 "pane closed"（`state` に混ぜない）。
  func testPaneClosedWhilePromptingIsAnError() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    prompt(wire, id: 1, paneId: fake.paneId)
    ControlServer.shared.emit(.paneClosed(paneId: fake.paneId))
    let response = wire.nextResponse()

    XCTAssertEqual(errorCode(response), -32004, "ペインの消滅は state ではなくエラー")
    XCTAssertEqual(errorMessage(response), "pane closed")
  }

  /// `timeoutMs` を明示すればその超過で `{timedOut:true}`。既定（1 時間）は測らない。
  func testPromptTimeoutAnswersTimedOut() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    let response = wire.request(
      id: 1, method: "prompt_agent", params: ["paneId": fake.paneId, "text": "x", "timeoutMs": 50])

    XCTAssertEqual(result(response)?["timedOut"] as? Bool, true, "時間切れは timedOut:true（エラーにしない）")
    XCTAssertEqual(fake.prompts.count, 1, "時間切れでも送信自体は済んでいる")
  }

  // MARK: - 送る前に弾く

  /// params の不備は target へ届く前に -32602。`timeoutMs` の上限は `wait_for_event` と同じ 24 時間。
  func testInvalidParamsAreRejectedBeforeSending() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let pane = fake.paneId
    var id = 0

    let bad: [[String: Any]] = [
      ["text": "x"], ["paneId": "\(pane)", "text": "x"], ["paneId": pane],
      ["paneId": pane, "text": 1],
      ["paneId": pane, "text": "x", "timeoutMs": 0],
      ["paneId": pane, "text": "x", "timeoutMs": -1],
      ["paneId": pane, "text": "x", "timeoutMs": 86_400_001],
      ["paneId": pane, "text": "x", "timeoutMs": "50"],
    ]
    for params in bad {
      id += 1
      XCTAssertEqual(
        errorCode(wire.request(id: id, method: "prompt_agent", params: params)), -32602,
        "\(params) は -32602")
    }
    XCTAssertTrue(fake.prompts.isEmpty, "弾いた要求は 1 件も target へ届いていない（何も送らない）")
  }

  /// 未知の pane は -32004 で、何も送らない。
  func testUnknownPaneIsNotFoundWithoutSending() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    let response = wire.request(
      id: 1, method: "prompt_agent", params: ["paneId": fake.paneId + 1, "text": "x"])

    XCTAssertEqual(errorCode(response), -32004)
    XCTAssertEqual(errorMessage(response), "pane not found")
    XCTAssertTrue(fake.prompts.isEmpty, "解決できない宛先には送らない")
  }

  /// target の拒否（busy / 未 mount）はそのまま wire に出て、待機は張られない。
  func testDomainRefusalIsAnsweredWithoutArmingAWait() {
    let fake = FakeControlTarget()
    fake.domainFailure = ControlError(
      code: -32000, message: "agent busy (state: working; answer a waiting agent with send_key)")
    let wire = startWire(target: fake)

    let response = wire.request(
      id: 1, method: "prompt_agent", params: ["paneId": fake.paneId, "text": "x"])
    XCTAssertEqual(errorCode(response), -32000, "target のコードをそのまま出す")
    XCTAssertEqual(
      errorMessage(response), "agent busy (state: working; answer a waiting agent with send_key)",
      "理由の文言も素通し（利用側が send_key へ切り替える手掛かり）")

    ControlServer.shared.emit(state(fake.paneId, "done"))
    wire.barrier()  // 拒んだ要求は done で起きない
  }

  /// 現在の履歴位置（即応答する要求の `seq`）。
  private func latestSeq(_ wire: ControlWire, id: Int) -> Int? {
    result(wire.request(id: id, method: "list_workspaces"))?["seq"] as? Int
  }
}
