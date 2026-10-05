import Foundation
import XCTest

@testable import Orbe

/// `wait_for_event`（状態変化の長ポーリング）の契約を固定する。フィルタの語・応答ペイロードの
/// 形・タイムアウト・1 接続に複数の待機を張れること。
///
/// 壊れると、`orb wait` と MCP の待機が黙って的外れになる。フィルタの語（`tabId` / `kinds` /
/// `timeoutMs` と kind の 4 語）が片側だけずれれば「全イベントで起きる」か「永遠に起きない」の
/// どちらかに倒れ、どちらも呼び出し側からは正常動作と区別がつかない。
///
/// イベントは本番と同じ `ControlServer.shared.emit(_:)` で駆動する。**実時間は測らない**——
/// 既定タイムアウト 30 秒を焼くとテストが 30 秒待つだけになるので、`timeoutMs` を明示指定した
/// 1 本だけがタイムアウト応答の形を見る。
extension ControlWireTests {

  /// `wait_for_event` を張り、登録が済んだことを barrier で確定させる。
  /// 待機は即時応答しないので、後続の `emit` が登録前に走らないことをここで決める
  /// （同一接続の行は受信順に処理されるため、barrier の応答＝前の行は処理済み）。
  private func armWait(_ wire: ControlWire, id: Int, params: [String: Any] = [:]) {
    wire.send(["jsonrpc": "2.0", "id": id, "method": "wait_for_event", "params": params])
    wire.barrier()
  }

  /// 応答から `event` オブジェクトを取り出す。
  private func event(_ response: [String: Any]?) -> [String: Any]? {
    (response?["result"] as? [String: Any])?["event"] as? [String: Any]
  }

  // MARK: - フィルタ

  /// `tabId` 不一致は素通りする（別タブのイベントで起こさない）。
  func testTabIdFilterIgnoresOtherTabs() {
    let wire = startWire(target: FakeControlTarget())
    armWait(wire, id: 1, params: ["tabId": 8001])

    ControlServer.shared.emit(
      .agentState(tabId: 8002, state: "working", message: nil, sessionId: nil))

    // barrier の応答が 1 行目に来る＝別タブのイベントは待機を消費していない。
    wire.barrier()
  }

  /// `kinds` に挙げた 4 語それぞれで起きる。語は `orb wait` / MCP が送る wire の綴りで書く
  /// （本番の `kind` から組むと、語を改名しても両側が揃って通ってしまう）。
  func testKindFilterWakesOnEachKind() {
    let wire = startWire(target: FakeControlTarget())
    var id = 0

    let cases: [(kind: String, event: ControlEvent)] = [
      ("agent_state", .agentState(tabId: 8101, state: "v", message: nil, sessionId: nil)),
      ("title", .title(tabId: 8102, title: "v")),
      ("pwd", .pwd(tabId: 8103, path: "v")),
      ("tab_closed", .tabClosed(tabId: 8104)),
    ]
    for (kind, event) in cases {
      id += 1
      armWait(wire, id: id, params: ["kinds": [kind]])
      ControlServer.shared.emit(event)

      let response = wire.nextResponse()
      XCTAssertEqual(response?["id"] as? Int, id, "kind \(kind) の待機が起きる")
      XCTAssertEqual(self.event(response)?["kind"] as? String, kind, "起きたイベントの kind がそのまま返る")
    }
  }

  /// `kinds` に無い kind は素通りする。
  func testKindFilterIgnoresOtherKinds() {
    let wire = startWire(target: FakeControlTarget())
    armWait(wire, id: 1, params: ["kinds": ["agent_state"]])

    ControlServer.shared.emit(.title(tabId: 8001, title: "t"))
    ControlServer.shared.emit(.pwd(tabId: 8001, path: "/tmp"))

    wire.barrier()
  }

  // MARK: - ペイロードの形

  /// 応答は `{event:{kind,tabId,value}}`。
  func testEventPayloadCarriesKindTabIdAndValue() {
    let wire = startWire(target: FakeControlTarget())
    armWait(wire, id: 1)

    ControlServer.shared.emit(.title(tabId: 8004, title: "zsh"))
    let payload = event(wire.nextResponse())

    XCTAssertEqual(payload?["kind"] as? String, "title")
    XCTAssertEqual(payload?["tabId"] as? Int, 8004)
    XCTAssertEqual(payload?["value"] as? String, "zsh")
  }

  /// `value` が nil のイベントは `value` キー自体を持たない（null を置かない）。
  func testEventWithoutValueOmitsTheValueKey() {
    let wire = startWire(target: FakeControlTarget())
    armWait(wire, id: 1)

    ControlServer.shared.emit(.tabClosed(tabId: 8005))
    let payload = event(wire.nextResponse())

    XCTAssertEqual(payload?["kind"] as? String, "tab_closed")
    XCTAssertNil(payload?["value"], "value 無しのイベントはキーごと落とす（null を置かない）")
  }

  // MARK: - タイムアウト

  /// `timeoutMs` を明示すればその超過で `{timedOut:true}` が返る。既定値（30 秒）は測らない。
  func testExplicitTimeoutAnswersTimedOut() {
    let wire = startWire(target: FakeControlTarget())

    wire.send([
      "jsonrpc": "2.0", "id": 1, "method": "wait_for_event", "params": ["timeoutMs": 50],
    ])
    let response = wire.nextResponse()

    XCTAssertEqual(response?["id"] as? Int, 1, "タイムアウト応答も待機を張った id で返る")
    XCTAssertEqual(
      (response?["result"] as? [String: Any])?["timedOut"] as? Bool, true,
      "timeout 超過は timedOut:true（エラーにしない）")
  }

  // MARK: - params の検証（待機を張る前に弾く）

  /// フィルタ・カーソル・タイムアウトの不備は、待機を張る前に -32602。
  /// - 未知 kind を素の `Set<String>` で通すと永久に一致せず**ただ時間切れになる**。既知の語に
  ///   混ざった 1 語でも、その 1 語ぶんだけ黙って待たない待機になる。
  /// - `kinds` の型違いは「フィルタ無し＝全通し」に化け、空配列は省略（＝全種）と正反対の待機になる。
  /// - `tabId` の型違いを nil に落とすと**全タブ**監視に化け、別タブのイベントを返す。
  /// - `timeoutMs` は正の Int で 24 時間まで（`asyncAfter(.milliseconds(_:))` の桁あふれを防ぐ）。
  func testInvalidParamsAreRejectedBeforeArmingAWait() {
    let wire = startWire(target: FakeControlTarget())
    var id = 0

    let bad: [[String: Any]] = [
      ["kinds": ["nosuch"]], ["kinds": ["agent_state", "nosuch"]],
      ["kinds": "agent_state"], ["kinds": [1, 2]], ["kinds": [String]()],
      ["tabId": "8001"],
      ["timeoutMs": 0], ["timeoutMs": -1], ["timeoutMs": 86_400_001], ["timeoutMs": "300"],
      ["after": "3"], ["after": -1], ["value": 42],
    ]
    for params in bad {
      id += 1
      XCTAssertEqual(
        errorCode(wire.request(id: id, method: "wait_for_event", params: params)), -32602,
        "\(params) は -32602")
    }

    ControlServer.shared.emit(
      .agentState(tabId: 8001, state: "done", message: nil, sessionId: nil))
    ControlServer.shared.emit(.pwd(tabId: 8001, path: "/x"))
    wire.barrier()  // 弾いた要求はどれも待機を張っていない
  }

  // MARK: - 1 接続に複数の待機

  /// 同じ接続に 2 件張れ、イベントは一致した待機をそれぞれ自分の `id` で起こす。
  /// 1 件目を後勝ちで上書きすると無応答になりクライアントがハングし、2 件目を拒めば
  /// `prompt_agent` の main 往復中に張られた `wait_for_event` が「PTY には書いたのに待てない」になる。
  func testTwoWaitsOnOneConnectionAnswerByTheirOwnIds() {
    let wire = startWire(target: FakeControlTarget())
    armWait(wire, id: 1, params: ["tabId": 8006])
    armWait(wire, id: 2, params: ["tabId": 8016])

    ControlServer.shared.emit(
      .agentState(tabId: 8016, state: "done", message: nil, sessionId: nil))
    XCTAssertEqual(wire.nextResponse()?["id"] as? Int, 2, "2 件目の待機が自分の id で起きる")

    ControlServer.shared.emit(
      .agentState(tabId: 8006, state: "done", message: nil, sessionId: nil))
    XCTAssertEqual(wire.nextResponse()?["id"] as? Int, 1, "1 件目は 2 件目に壊されず生きている")
  }

  /// 応答を返した待機は解けており、同じイベントで二度起きない。
  func testWaitIsClearedAfterResponding() {
    let wire = startWire(target: FakeControlTarget())
    armWait(wire, id: 1)
    ControlServer.shared.emit(.pwd(tabId: 8007, path: "/a"))
    XCTAssertEqual(wire.nextResponse()?["id"] as? Int, 1)

    armWait(wire, id: 2)

    ControlServer.shared.emit(.pwd(tabId: 8008, path: "/b"))
    let response = wire.nextResponse()

    XCTAssertEqual(response?["id"] as? Int, 2, "解けた待機の後は次の待機が普通に働く")
    XCTAssertEqual(event(response)?["tabId"] as? Int, 8008)
    wire.barrier()  // 解けた id 1 が 2 つ目のイベントで再び書かれていない
  }
}
