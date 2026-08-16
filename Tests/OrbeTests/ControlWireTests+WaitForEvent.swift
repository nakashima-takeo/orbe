import Foundation
import XCTest

@testable import Orbe

/// `wait_for_event`（状態変化の長ポーリング）の契約を固定する。フィルタの語・応答ペイロードの
/// 形・タイムアウト・1 接続 1 待機の規律。
///
/// 壊れると、`orb wait` と MCP の待機が黙って的外れになる。フィルタの語（`paneId` / `kinds` /
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

  /// `paneId` 一致で起きる。
  func testPaneIdFilterWakesOnMatch() {
    let wire = startWire(target: FakeControlTarget())
    armWait(wire, id: 1, params: ["paneId": 8001])

    ControlServer.shared.emit(ControlEvent(kind: "agent_state", paneId: 8001, value: "working"))
    let response = wire.nextResponse()

    XCTAssertEqual(response?["id"] as? Int, 1, "待機を張った要求の id で応答が返る")
    XCTAssertEqual(event(response)?["paneId"] as? Int, 8001)
  }

  /// `paneId` 不一致は素通りする（別ペインのイベントで起こさない）。
  func testPaneIdFilterIgnoresOtherPanes() {
    let wire = startWire(target: FakeControlTarget())
    armWait(wire, id: 1, params: ["paneId": 8001])

    ControlServer.shared.emit(ControlEvent(kind: "agent_state", paneId: 8002, value: "working"))

    // barrier の応答が 1 行目に来る＝別ペインのイベントは待機を消費していない。
    wire.barrier()
  }

  /// `kinds` に挙げた 4 語それぞれで起きる。kind の語彙が片側だけ変わるとここが落ちる。
  func testKindFilterWakesOnEachKind() {
    let wire = startWire(target: FakeControlTarget())
    var id = 0

    for kind in ["agent_state", "pane_title", "pwd", "pane_closed"] {
      id += 1
      armWait(wire, id: id, params: ["kinds": [kind]])
      ControlServer.shared.emit(ControlEvent(kind: kind, paneId: 8100 + id, value: "v"))

      let response = wire.nextResponse()
      XCTAssertEqual(response?["id"] as? Int, id, "kind \(kind) の待機が起きる")
      XCTAssertEqual(event(response)?["kind"] as? String, kind, "起きたイベントの kind がそのまま返る")
    }
  }

  /// `kinds` に無い kind は素通りする。
  func testKindFilterIgnoresOtherKinds() {
    let wire = startWire(target: FakeControlTarget())
    armWait(wire, id: 1, params: ["kinds": ["agent_state"]])

    ControlServer.shared.emit(ControlEvent(kind: "pane_title", paneId: 8001, value: "t"))
    ControlServer.shared.emit(ControlEvent(kind: "pwd", paneId: 8001, value: "/tmp"))

    wire.barrier()
  }

  /// フィルタ省略は全通し。
  func testWithoutFiltersAnyEventWakes() {
    let wire = startWire(target: FakeControlTarget())
    armWait(wire, id: 1)

    ControlServer.shared.emit(ControlEvent(kind: "pwd", paneId: 8003, value: "/tmp/x"))
    let response = wire.nextResponse()

    XCTAssertEqual(response?["id"] as? Int, 1, "フィルタ省略なら kind も paneId も問わず起きる")
    XCTAssertEqual(event(response)?["kind"] as? String, "pwd")
  }

  // MARK: - ペイロードの形

  /// 応答は `{event:{kind,paneId,value}}`。
  func testEventPayloadCarriesKindPaneIdAndValue() {
    let wire = startWire(target: FakeControlTarget())
    armWait(wire, id: 1)

    ControlServer.shared.emit(ControlEvent(kind: "pane_title", paneId: 8004, value: "zsh"))
    let payload = event(wire.nextResponse())

    XCTAssertEqual(payload?["kind"] as? String, "pane_title")
    XCTAssertEqual(payload?["paneId"] as? Int, 8004)
    XCTAssertEqual(payload?["value"] as? String, "zsh")
  }

  /// `value` が nil のイベントは `value` キー自体を持たない（null を置かない）。
  func testEventWithoutValueOmitsTheValueKey() {
    let wire = startWire(target: FakeControlTarget())
    armWait(wire, id: 1)

    ControlServer.shared.emit(ControlEvent(kind: "pane_closed", paneId: 8005, value: nil))
    let payload = event(wire.nextResponse())

    XCTAssertEqual(payload?["kind"] as? String, "pane_closed")
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

  /// 未知 kind は待機を張らずに -32602。素の `Set<String>` フィルタとして通すと永久に一致せず
  /// **ただ時間切れになる**ので、呼び出し側（`orb wait` / MCP）は「何も起きなかった」と区別できない。
  func testUnknownKindIsRejectedInsteadOfSilentlyNeverMatching() {
    let wire = startWire(target: FakeControlTarget())

    XCTAssertEqual(
      errorCode(wire.request(id: 1, method: "wait_for_event", params: ["kinds": ["nosuch"]])),
      -32602, "未知 kind は -32602")
    // 既知の語に混ざった 1 語でも弾く（通ると、その 1 語ぶんだけ黙って待たない待機になる）。
    XCTAssertEqual(
      errorCode(
        wire.request(
          id: 2, method: "wait_for_event", params: ["kinds": ["agent_state", "nosuch"]])),
      -32602, "既知 kind に混ざった未知 kind も -32602")
  }

  /// `kinds` が `[String]` でなければ -32602（黙って「フィルタ無し＝全通し」に化けない）。
  /// 空配列も同じ——`Set([])` はどの kind にも一致せず、省略（＝全種）とは正反対の待機になる。
  func testWronglyTypedKindsAreRejected() {
    let wire = startWire(target: FakeControlTarget())

    XCTAssertEqual(
      errorCode(wire.request(id: 1, method: "wait_for_event", params: ["kinds": "agent_state"])),
      -32602, "文字列を直接渡した kinds は -32602")
    XCTAssertEqual(
      errorCode(wire.request(id: 2, method: "wait_for_event", params: ["kinds": [1, 2]])),
      -32602, "要素が文字列でない kinds は -32602")
    XCTAssertEqual(
      errorCode(wire.request(id: 3, method: "wait_for_event", params: ["kinds": [String]()])),
      -32602, "空の kinds は -32602（省略＝全種と取り違えて黙って時間切れにしない）")
  }

  /// `paneId` が Int でなければ -32602。黙って nil に落とすと絞り込みが消えて**全ペイン**監視に
  /// 化け、別ペインのイベントを「待っていたもの」として返す（kinds の取りこぼしより悪い）。
  func testWronglyTypedPaneIdIsRejected() {
    let wire = startWire(target: FakeControlTarget())

    XCTAssertEqual(
      errorCode(wire.request(id: 1, method: "wait_for_event", params: ["paneId": "8001"])),
      -32602, "文字列の paneId は -32602")
  }

  /// `timeoutMs` は正の Int で 24 時間まで。0・負・非 Int・上限超過は -32602。
  /// 上限を置くのは `asyncAfter(.milliseconds(_:))` が巨大値でオーバーフローするため。
  func testInvalidTimeoutMsIsRejected() {
    let wire = startWire(target: FakeControlTarget())
    var id = 0

    for bad in [0, -1, 86_400_001] as [Any] {
      id += 1
      XCTAssertEqual(
        errorCode(wire.request(id: id, method: "wait_for_event", params: ["timeoutMs": bad])),
        -32602, "timeoutMs \(bad) は -32602")
    }
    id += 1
    XCTAssertEqual(
      errorCode(wire.request(id: id, method: "wait_for_event", params: ["timeoutMs": "300"])),
      -32602, "非 Int の timeoutMs は -32602")
  }

  /// 弾いた待機は**張られていない**（待機枠を食い潰さない）。直後の正しい待機が受理され、
  /// -32005（1 接続 2 件目）にならないことで確かめる。
  func testRejectedWaitDoesNotOccupyTheSingleWaitSlot() {
    let wire = startWire(target: FakeControlTarget())
    XCTAssertEqual(
      errorCode(wire.request(id: 1, method: "wait_for_event", params: ["kinds": ["nosuch"]])),
      -32602)

    armWait(wire, id: 2)  // barrier が 1 行目に来る＝-32005 を書いていない
    ControlServer.shared.emit(ControlEvent(kind: "pwd", paneId: 8009, value: "/x"))
    XCTAssertEqual(wire.nextResponse()?["id"] as? Int, 2, "弾いた後も次の待機が普通に働く")
  }

  // MARK: - 1 接続 1 待機

  /// 2 件目の `wait_for_event` は -32005 で即拒否し、1 件目は生きたままイベントに応答する
  /// （後勝ちで上書きすると 1 件目が無応答になりクライアントがハングする）。
  func testSecondWaitIsRejectedAndFirstStaysAlive() {
    let wire = startWire(target: FakeControlTarget())
    armWait(wire, id: 1)  // timeoutMs は既定のまま——短くすると timeout 応答が先に来て順序が入れ替わる

    XCTAssertEqual(
      errorCode(wire.request(id: 2, method: "wait_for_event")), -32005,
      "2 件目の待機は -32005 で即拒否")

    ControlServer.shared.emit(ControlEvent(kind: "agent_state", paneId: 8006, value: "done"))
    let response = wire.nextResponse()

    XCTAssertEqual(response?["id"] as? Int, 1, "拒否された 2 件目は 1 件目を壊さない")
  }

  /// 応答を返した待機は解けており、次の `wait_for_event` は受理される。
  func testWaitIsClearedAfterRespondingSoNextWaitIsAccepted() {
    let wire = startWire(target: FakeControlTarget())
    armWait(wire, id: 1)
    ControlServer.shared.emit(ControlEvent(kind: "pwd", paneId: 8007, value: "/a"))
    XCTAssertEqual(wire.nextResponse()?["id"] as? Int, 1)

    // barrier が 1 行目に来る＝2 件目の待機は -32005 を書いていない（受理されている）。
    armWait(wire, id: 2)

    ControlServer.shared.emit(ControlEvent(kind: "pwd", paneId: 8008, value: "/b"))
    let response = wire.nextResponse()

    XCTAssertEqual(response?["id"] as? Int, 2, "解けた待機の後は次の待機が普通に働く")
    XCTAssertEqual(event(response)?["paneId"] as? Int, 8008)
  }
}
