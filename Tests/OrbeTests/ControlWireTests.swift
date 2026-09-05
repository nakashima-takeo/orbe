import Foundation
import XCTest

@testable import Orbe

/// 制御プロトコル（`control.sock` 上の改行区切り JSON-RPC 2.0）の wire 契約を、socketpair 上の
/// 実 `Connection` で固定する。ここが測るのはエンベロープの形と不正入力の扱い。
///
/// 壊れると、`orb` / MCP ブリッジ / `orbe-report` が読む応答の形が黙って変わる。とくに
/// **不正入力への応答が消えると、1 行応答を待って読むクライアントはそのままハングする**
/// （#62）。応答を出さない契約を持つのは `completion_update` / `completion_end` の 2 つだけで、
/// これが崩れると打鍵ごとに zsh 補完の fd へ行が積み、accept 応答が締切内に読めなくなる。
///
/// エラーコードの語彙は `docs/spec/control/api.md` の「エラー」節と 1 対 1 に対応する。
/// 片方だけ変えたらここが落ちる。
final class ControlWireTests: OrbeTestCase {
  /// 駆動台。後始末は `tearDown` が持つ（各テストの `defer` に散らさない）。
  private var wire: ControlWire?

  override func tearDown() {
    wire?.teardown()
    wire = nil
    super.tearDown()
  }

  /// Fake target 付きの駆動台を立てる。
  func startWire(target: FakeControlTarget) -> ControlWire {
    let w = ControlWire(target: target)
    wire = w
    return w
  }

  /// target 不在（ウィンドウ未接続）の駆動台を立てる。
  func startWireWithoutTarget() -> ControlWire {
    let w = ControlWire(target: nil)
    wire = w
    return w
  }

  /// 応答のエラーコード。error を持たない応答なら nil。
  func errorCode(_ response: [String: Any]?) -> Int? {
    (response?["error"] as? [String: Any])?["code"] as? Int
  }

  // MARK: - エンベロープ

  /// 成功応答は jsonrpc / id / result の 3 キーで、error を持たない。
  func testSuccessEnvelopeCarriesResultAndNoError() {
    let fake = FakeControlTarget()
    fake.workspaces = [["id": 1, "name": "main"]]
    let wire = startWire(target: fake)

    wire.send(["jsonrpc": "2.0", "id": 11, "method": "list_workspaces"])
    let response = wire.nextResponse()

    XCTAssertEqual(response?["jsonrpc"] as? String, "2.0", "エンベロープは JSON-RPC 2.0 を名乗る")
    XCTAssertEqual(response?["id"] as? Int, 11, "id は送ったものをそのまま返す")
    XCTAssertNotNil(response?["result"], "成功は result を持つ")
    XCTAssertNil(response?["error"], "成功応答に error を同居させない")
    let result = response?["result"] as? [String: Any]
    XCTAssertEqual((result?["workspaces"] as? [[String: Any]])?.count, 1, "result は target の戻りを包む")
  }

  /// 失敗応答は error{code,message} を持ち、result を持たない。
  func testFailureEnvelopeCarriesErrorAndNoResult() {
    let wire = startWire(target: FakeControlTarget())

    wire.send(["jsonrpc": "2.0", "id": 12, "method": "no_such_method"])
    let response = wire.nextResponse()

    XCTAssertEqual(response?["jsonrpc"] as? String, "2.0")
    XCTAssertEqual(response?["id"] as? Int, 12, "失敗でも id は返す（クライアントが要求と対応づける）")
    XCTAssertNil(response?["result"], "失敗応答に result を同居させない")
    let error = response?["error"] as? [String: Any]
    XCTAssertNotNil(error?["code"] as? Int, "error は code を持つ")
    XCTAssertNotNil(error?["message"] as? String, "error は message を持つ")
  }

  /// id 省略（通知）でも応答は返り、id は null になる（黙殺しない）。
  func testMissingIdStillAnswersWithNullId() {
    let wire = startWire(target: FakeControlTarget())

    wire.send(["jsonrpc": "2.0", "method": "list_workspaces"])
    let response = wire.nextResponse()

    XCTAssertTrue(response?["id"] is NSNull, "id 無しの要求への応答は id: null")
    XCTAssertNotNil(response?["result"], "id が無くても応答は返す")
  }

  /// id の型は保つ（文字列 id は文字列のまま返る）。
  func testStringIdIsEchoedAsString() {
    let wire = startWire(target: FakeControlTarget())

    wire.send(["jsonrpc": "2.0", "id": "abc-1", "method": "list_workspaces"])
    let response = wire.nextResponse()

    XCTAssertEqual(response?["id"] as? String, "abc-1", "id は型ごと保つ（数値へ丸めない）")
  }

  /// params 省略は空 params 扱いで、params を要さないメソッドは成功する。
  func testMissingParamsIsTreatedAsEmpty() {
    let wire = startWire(target: FakeControlTarget())

    wire.send(["jsonrpc": "2.0", "id": 13, "method": "list_tabs"])
    let response = wire.nextResponse()

    XCTAssertNotNil(response?["result"], "params 省略は空 params 扱い（エラーにしない）")
  }

  // MARK: - method の解決

  /// 未知 method は -32601。
  func testUnknownMethodIsMethodNotFound() {
    let wire = startWire(target: FakeControlTarget())

    wire.send(["jsonrpc": "2.0", "id": 14, "method": "teleport_tab"])

    XCTAssertEqual(errorCode(wire.nextResponse()), -32601, "未知 method は -32601")
  }

  /// 未知の `completion_*` も -32601。補完系は宛先解決ガードより前で分岐するため、
  /// target の有無に依らずこの経路を通る。
  func testUnknownCompletionMethodIsMethodNotFound() {
    let wire = startWireWithoutTarget()

    wire.send(["jsonrpc": "2.0", "id": 15, "method": "completion_teleport"])

    XCTAssertEqual(errorCode(wire.nextResponse()), -32601, "未知の completion_* も -32601")
  }

  // MARK: - target 不在

  /// ウィンドウ未接続（target なし）は -32000 "no window"。
  func testWithoutTargetIsNoWindow() {
    let wire = startWireWithoutTarget()

    wire.send(["jsonrpc": "2.0", "id": 16, "method": "list_tabs"])
    let response = wire.nextResponse()

    XCTAssertEqual(errorCode(response), -32000, "target 不在は -32000")
    XCTAssertEqual(
      (response?["error"] as? [String: Any])?["message"] as? String, "no window",
      "message も契約の一部（クライアントが「Orbe 未起動」と区別する）")
  }

  /// target 不在でも `completion_update` / `completion_end` は無応答のまま。応答を書くと
  /// 打鍵ごとに zsh 補完の fd へ行が積み、accept 応答が 1 秒の締切内に読めなくなる。
  func testCompletionSilentMethodsStaySilentWithoutTarget() {
    let wire = startWireWithoutTarget()

    wire.send([
      "jsonrpc": "2.0", "id": 17, "method": "completion_update",
      "params": ["buffer": "l", "cursor": 1],
    ])
    wire.send(["jsonrpc": "2.0", "id": 18, "method": "completion_end", "params": [:]])

    // barrier の応答が 1 行目に来る＝上の 2 行は 1 バイトも書かせていない。
    wire.barrier()
  }

  // MARK: - 不正入力（#62）

  /// JSON として読めない行は -32700 で、id は null（要求から id を取れない）。
  func testBrokenJsonIsParseError() {
    let wire = startWire(target: FakeControlTarget())

    wire.sendRaw(Data("{\"method\": \n".utf8))
    let response = wire.nextResponse()

    XCTAssertEqual(errorCode(response), -32700, "壊れた JSON は -32700。黙って捨てるとクライアントがハングする")
    XCTAssertTrue(response?["id"] is NSNull, "読めない行から id は取れないので null")
  }

  /// UTF-8 として不正なバイト列も -32700。
  func testInvalidUtf8IsParseError() {
    let wire = startWire(target: FakeControlTarget())

    // {"a":"<0xff 0xfe>"} ——構文は JSON だが文字列が UTF-8 として復号できない。
    wire.sendRaw(Data([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xFF, 0xFE, 0x22, 0x7D, 0x0A]))

    XCTAssertEqual(errorCode(wire.nextResponse()), -32700, "不正 UTF-8 は -32700")
  }

  /// 最上位スカラは -32700。`JSONSerialization` は `.fragmentsAllowed` 無しで最上位スカラを
  /// 受け付けず throw するため、「JSON テキストとして読めない」側に落ちる（実測で確定した挙動）。
  /// パーサを広げて -32600 に見せる方向へは直さない——受け入れる入力を増やす変更になる。
  func testTopLevelScalarIsParseError() {
    let wire = startWire(target: FakeControlTarget())

    wire.sendRaw(Data("42\n".utf8))

    XCTAssertEqual(errorCode(wire.nextResponse()), -32700, "最上位スカラは JSON テキストとして読めない扱い")
  }

  /// JSON だがリクエストオブジェクトでない（配列）は -32600。parse error と呼ぶのは嘘になる。
  func testJsonArrayIsInvalidRequest() {
    let wire = startWire(target: FakeControlTarget())

    wire.sendRaw(Data("[1,2]\n".utf8))
    let response = wire.nextResponse()

    XCTAssertEqual(errorCode(response), -32600, "配列は読めている＝parse error ではなく invalid request")
    XCTAssertTrue(response?["id"] is NSNull, "配列に id は無いので null")
  }

  /// method を持たないオブジェクトは -32600。id は取れるので返す。
  func testObjectWithoutMethodIsInvalidRequestAndKeepsId() {
    let wire = startWire(target: FakeControlTarget())

    wire.send(["jsonrpc": "2.0", "id": 19, "params": ["tabId": 1]])
    let response = wire.nextResponse()

    XCTAssertEqual(errorCode(response), -32600, "method 欠落は invalid request")
    XCTAssertEqual(response?["id"] as? Int, 19, "オブジェクトからは id が取れるので返す")
  }

  /// 不正な行の後も接続は生きており、続く有効要求へ応答する（1 行の失敗で接続を畳まない）。
  func testConnectionSurvivesInvalidLine() {
    let wire = startWire(target: FakeControlTarget())

    wire.sendRaw(Data("not json\n".utf8))
    XCTAssertEqual(errorCode(wire.nextResponse()), -32700)

    wire.send(["jsonrpc": "2.0", "id": 20, "method": "list_workspaces"])
    let response = wire.nextResponse()

    XCTAssertEqual(response?["id"] as? Int, 20, "不正行の後も同じ接続で応答が返る")
    XCTAssertNotNil(response?["result"])
  }
}
