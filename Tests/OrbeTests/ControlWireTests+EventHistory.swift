import Foundation
import XCTest

@testable import Orbe

/// イベント履歴の wire 契約——全イベントの `seq`・成功応答が刻む `seq`・`wait_for_event` の
/// `after`（履歴の replay）と `value`（kind 固有値の一致）——を socketpair 上の実 `Connection` で固定する。
///
/// 壊れると何が起きるか: `orb pane send --json` の `seq` を `orb wait --after` に渡す手順が黙って
/// 機能しなくなる。応答の `seq` が「その操作以前の履歴位置」でなくなれば、`after` はその操作が
/// 引き起こした遷移を飛ばすか、前ターンの `done` を掴む。イベントで完結した応答の `seq` が最新に
/// 化ければ、replay で返したイベントと応答の間のイベントを次の `after` で取りこぼす。`-32006` が
/// `-32602` に混ざれば、呼び出し側は「seq を取り直せ」と「呼び方が間違っている」を区別できない。
///
/// `ControlServer.shared` の履歴はプロセス寿命で溜まり続け、他のテストが残した `SurfaceView` の解放
/// （`pane_closed`）がいつ割り込むかは決められない。seq はリテラルで書かず直前の応答から読み、
/// 隣接（`+ 1`）ではなく**前後関係**（自分の pane に絞った一致・大小）で言う。`+ 1` の厳密さは L1 が持つ。
extension ControlWireTests {
  /// 応答時点の履歴位置（成功応答の最上位 `seq`）。
  private func seq(_ response: [String: Any]?) -> Int? {
    (response?["result"] as? [String: Any])?["seq"] as? Int
  }

  private func event(_ response: [String: Any]?) -> [String: Any]? {
    (response?["result"] as? [String: Any])?["event"] as? [String: Any]
  }

  /// 現在の履歴位置を読む（即応答する要求の `seq`）。
  private func currentSeq(_ wire: ControlWire, id: Int) -> Int {
    seq(wire.request(id: id, method: "list_workspaces")) ?? -1
  }

  private func armWait(_ wire: ControlWire, id: Int, params: [String: Any] = [:]) {
    wire.send(["jsonrpc": "2.0", "id": id, "method": "wait_for_event", "params": params])
    wire.barrier()
  }

  private func done(_ paneId: Int, message: String? = nil, sessionId: String? = nil) -> ControlEvent
  {
    .agentState(paneId: paneId, state: "done", message: message, sessionId: sessionId)
  }

  // MARK: - seq

  /// kind・pane を問わず 1 本の seq が進み、event 応答の `event.seq` と最上位 `seq` は
  /// そのイベント自身の seq。
  func testEveryEventCarriesTheNextSeqOnOneCounter() {
    let wire = startWire(target: FakeControlTarget())
    var previous = currentSeq(wire, id: 1)
    let events: [ControlEvent] = [
      done(8201), .paneTitle(paneId: 8202, title: "t"), .pwd(paneId: 8203, path: "/p"),
      .paneClosed(paneId: 8204),
    ]

    for (index, next) in events.enumerated() {
      armWait(wire, id: 10 + index, params: ["paneId": next.paneId])
      ControlServer.shared.emit(next)
      let response = wire.nextResponse()

      let assigned = event(response)?["seq"] as? Int ?? -1
      XCTAssertGreaterThan(
        assigned, previous, "\(next.kind) にも同じ 1 本のカウンタで前より大きい seq が振られる")
      XCTAssertEqual(seq(response), assigned, "イベントで完結した応答の seq はそのイベントの seq")
      previous = assigned
    }
  }

  /// 成功応答の最上位に `seq`（応答時点の履歴位置）が載り、エラー応答には載らない。
  /// `{ok:true}` 系も `list_*` も `spawn` も同じ。
  func testSuccessResponsesCarryTheHistoryPositionAndErrorsDoNot() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let start = currentSeq(wire, id: 1)
    let pane = fake.paneId

    let successes: [(String, [String: Any])] = [
      ("list_panes", [:]),
      ("send_text", ["paneId": pane, "text": "hi"]),
      ("send_key", ["paneId": pane, "key": "enter"]),
      ("spawn", [:]),
      ("spawn_agent", ["command": "codex"]),
    ]
    var position = start
    for (index, entry) in successes.enumerated() {
      let seq = seq(wire.request(id: 10 + index, method: entry.0, params: entry.1)) ?? -1
      XCTAssertGreaterThanOrEqual(
        seq, position, "\(entry.0) の成功応答は最上位に応答時点の seq を持つ（履歴位置は戻らない）")
      position = seq
    }

    ControlServer.shared.emit(done(8205))
    XCTAssertGreaterThan(
      currentSeq(wire, id: 20), position, "イベントが起きた後の応答は進んだ履歴位置を刻む")

    let failure = wire.request(id: 21, method: "send_text", params: ["paneId": pane])
    XCTAssertNotNil(failure?["error"], "前提: -32602 の失敗応答")
    XCTAssertNil(failure?["seq"], "エラー応答の最上位に seq は載らない")
    XCTAssertNil(
      (failure?["error"] as? [String: Any])?["seq"], "エラー応答の error の中にも seq は載らない")
  }

  /// `agent_state` の event は、その遷移の報告が運んだ `message` / `sessionId` を載せ、無ければ
  /// キーごと落とす（null を置かない）。
  func testAgentStateEventCarriesMessageAndSessionIdWhenReported() {
    let wire = startWire(target: FakeControlTarget())

    armWait(wire, id: 1, params: ["paneId": 8206])
    ControlServer.shared.emit(done(8206, message: "終わりました", sessionId: "sess-8206"))
    let full = event(wire.nextResponse())
    XCTAssertEqual(full?["message"] as? String, "終わりました", "報告の文言がイベントに載る")
    XCTAssertEqual(full?["sessionId"] as? String, "sess-8206", "報告の session id がイベントに載る")

    armWait(wire, id: 2, params: ["paneId": 8206])
    ControlServer.shared.emit(done(8206))
    let bare = event(wire.nextResponse())
    XCTAssertEqual(bare?["value"] as? String, "done", "前提: 同じ pane の agent_state")
    XCTAssertNil(bare?["message"], "文言の無い報告は message キーを持たない")
    XCTAssertNil(bare?["sessionId"], "session id の無い報告は sessionId キーを持たない")
  }

  // MARK: - after（履歴の replay）

  /// `after` より後にフィルタ一致のイベントが既に起きていれば、待たずにそのイベントで返る。
  /// 返す `seq` はそのイベントの seq で、応答時点の最新ではない。
  func testAfterReplaysAnEventThatAlreadyHappenedWithoutWaiting() {
    let wire = startWire(target: FakeControlTarget())
    let before = currentSeq(wire, id: 1)

    ControlServer.shared.emit(done(8207))
    ControlServer.shared.emit(.pwd(paneId: 8208, path: "/later"))
    let latest = currentSeq(wire, id: 2)

    let response = wire.request(
      id: 3, method: "wait_for_event", params: ["after": before, "paneId": 8207])

    XCTAssertEqual(event(response)?["paneId"] as? Int, 8207, "既に起きたイベントで即返る")
    let replayed = event(response)?["seq"] as? Int ?? -1
    XCTAssertGreaterThan(replayed, before, "返るのは after より後のイベント")
    XCTAssertEqual(seq(response), replayed, "応答の seq は返したイベントの seq")
    XCTAssertLessThan(
      replayed, latest, "応答の seq は最新ではない（最新に化けると次の after で pwd を取りこぼす）")

    ControlServer.shared.emit(done(8207))
    wire.barrier()  // replay で返した要求は待機を残していない（残ると同じ id の応答がもう 1 行届く）
  }

  /// 一致が複数あれば seq 昇順で**最初**の一致を返す（最新ではない）。
  func testAfterReturnsTheEarliestMatchNotTheLatest() {
    let wire = startWire(target: FakeControlTarget())
    let before = currentSeq(wire, id: 1)

    ControlServer.shared.emit(
      .agentState(paneId: 8209, state: "working", message: nil, sessionId: nil))
    ControlServer.shared.emit(done(8209, message: "first"))
    ControlServer.shared.emit(done(8209, message: "second"))
    wire.barrier()

    let response = wire.request(
      id: 3, method: "wait_for_event",
      params: ["after": before, "paneId": 8209, "value": "done"])

    XCTAssertEqual(event(response)?["message"] as? String, "first", "seq 昇順で最初の一致")

    ControlServer.shared.emit(done(8209, message: "third"))
    wire.barrier()  // replay で返した要求は待機を残していない
  }

  /// `after` 以後に一致が無ければ従来どおり待ち、後続のイベントで起きる。
  func testAfterWithoutAPastMatchWaitsForTheNextEvent() {
    let wire = startWire(target: FakeControlTarget())
    ControlServer.shared.emit(
      .agentState(paneId: 8210, state: "working", message: nil, sessionId: nil))
    let before = currentSeq(wire, id: 1)

    armWait(wire, id: 2, params: ["after": before, "paneId": 8210, "value": "done"])
    ControlServer.shared.emit(done(8210))
    let response = wire.nextResponse()

    XCTAssertEqual(response?["id"] as? Int, 2, "履歴に一致が無ければ待機を張って後続で起きる")
    XCTAssertGreaterThan(event(response)?["seq"] as? Int ?? -1, before)
  }

  /// `after` が最新 seq より大きい値は観測しえない＝呼び出し側のバグとして -32602。待機は張らない。
  func testAfterBeyondTheLatestSeqIsRejectedWithoutArming() {
    let wire = startWire(target: FakeControlTarget())
    let latest = currentSeq(wire, id: 1)

    XCTAssertEqual(
      errorCode(
        wire.request(id: 2, method: "wait_for_event", params: ["after": latest + 100_000])),
      -32602, "最新より大きい after は -32602")

    ControlServer.shared.emit(.pwd(paneId: 8211, path: "/x"))
    wire.barrier()  // 弾いた待機がイベントで起きていない
  }

  /// `after` が保持範囲より古ければ -32006（対処は seq を取り直す）。-32602 とは分ける。
  func testAfterOlderThanRetainedHistoryIsEvicted() {
    let wire = startWire(target: FakeControlTarget())
    let old = currentSeq(wire, id: 1)
    // seq `old + 1` を落とすには容量ぶん＋ 1 件を積む。容量は `ControlServer` の履歴（4096）。
    let capacity = 4096
    for _ in 0...capacity { ControlServer.shared.emit(.pwd(paneId: 8212, path: "/flood")) }
    let latest = currentSeq(wire, id: 2)
    XCTAssertGreaterThanOrEqual(latest, old + capacity + 1, "前提: 容量 + 1 件以上を積んだ")

    let response = wire.request(id: 3, method: "wait_for_event", params: ["after": old])

    XCTAssertEqual(errorCode(response), -32006, "落ちた seq を指す after は -32006")
    XCTAssertEqual(
      (response?["error"] as? [String: Any])?["message"] as? String, "event history evicted",
      "message も契約の一部（クライアントが seq の取り直しを判断する）")
    // 保持範囲の内側は replay できる。最古ぴったりは他テストの残骸（pane_closed）が割り込むと
    // 落ちうるので 1 つ内側を指す（境界の厳密さは L1 が持つ）。
    let retained = latest - capacity + 1
    XCTAssertEqual(
      event(wire.request(id: 4, method: "wait_for_event", params: ["after": retained]))?["seq"]
        as? Int, retained + 1, "保持範囲の内側の after は replay できる")

    ControlServer.shared.emit(.pwd(paneId: 8212, path: "/after"))
    wire.barrier()  // -32006 で弾いた要求も replay で返した要求も待機を残していない
  }

  /// `after` の型違い・負、`value` の非文字列は待機を張る前に -32602。
  func testWronglyTypedAfterAndValueAreRejected() {
    let wire = startWire(target: FakeControlTarget())
    var id = 0

    for bad in [["after": "3"], ["after": -1], ["value": 42]] as [[String: Any]] {
      id += 1
      XCTAssertEqual(
        errorCode(wire.request(id: id, method: "wait_for_event", params: bad)), -32602,
        "\(bad) は -32602")
    }
    ControlServer.shared.emit(.pwd(paneId: 8213, path: "/x"))
    wire.barrier()  // どれも待機を張っていない
  }

  // MARK: - value

  /// `value` は kind 固有値の完全一致でだけ起きる（agent_state なら状態語）。
  func testValueFilterWakesOnlyOnTheMatchingValue() {
    let wire = startWire(target: FakeControlTarget())
    armWait(wire, id: 1, params: ["paneId": 8214, "value": "done"])

    ControlServer.shared.emit(
      .agentState(paneId: 8214, state: "working", message: nil, sessionId: nil))
    ControlServer.shared.emit(.paneTitle(paneId: 8214, title: "done!"))
    wire.barrier()  // 別の状態語・部分一致のタイトルでは起きない

    ControlServer.shared.emit(done(8214))
    let response = wire.nextResponse()
    XCTAssertEqual(response?["id"] as? Int, 1, "一致する value で起きる")
    XCTAssertEqual(event(response)?["value"] as? String, "done")
  }
}
