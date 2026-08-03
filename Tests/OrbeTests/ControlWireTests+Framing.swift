import Foundation
import XCTest

@testable import Orbe

/// 行 framing の**配線**を固定する。分割規則そのもの（改行で切る・空行を捨てる・上限超過を
/// 報告する）は `ControlLineFramerTests` が純ロジックとして持つので、ここが見るのは
/// `LineFramer` が `Connection` に正しく繋がっているか——TCP 境界と行境界が独立でも
/// 1 要求 1 応答が保たれるか、上限超過の報告が実際に接続を畳むか——だけ。
///
/// 壊れると、要求が 2 つ繋がって届いた日にだけ応答が 1 つ落ちる、あるいは要求が途中で切れて
/// 届いた日にだけ応答が 2 つ出る。どちらも負荷やバッファ境界に依存して散発的に起き、
/// クライアント側では「たまに固まる」としか見えない。
extension ControlWireTests {

  /// 1 回の write に 2 リクエストが入っていても、送った順に 2 応答が返る。
  func testTwoRequestsInOneWriteGetTwoResponsesInOrder() {
    let wire = startWire(target: FakeControlTarget())

    let first = #"{"jsonrpc":"2.0","id":41,"method":"list_workspaces"}"#
    let second = #"{"jsonrpc":"2.0","id":42,"method":"list_panes"}"#
    wire.sendRaw(Data("\(first)\n\(second)\n".utf8))

    XCTAssertEqual(wire.nextResponse()?["id"] as? Int, 41, "1 つ目の応答が先に返る")
    XCTAssertEqual(wire.nextResponse()?["id"] as? Int, 42, "2 つ目の応答が後に返る（順序を入れ替えない）")
  }

  /// 1 リクエストが 2 回の write に分かれて届いても、応答は 1 つだけ。
  func testRequestSplitAcrossWritesGetsOneResponse() {
    let wire = startWire(target: FakeControlTarget())

    // 分割位置は JSON の途中（キー名の内側）。TCP 境界と行境界は無関係だと示す。
    wire.sendRaw(Data(#"{"jsonrpc":"2.0","id":43,"method":"list_wor"#.utf8))
    wire.sendRaw(Data("kspaces\"}\n".utf8))

    XCTAssertEqual(wire.nextResponse()?["id"] as? Int, 43, "分割されても 1 要求として組み直される")
    wire.barrier()  // barrier が 1 行目に来る＝余分な応答は出ていない
  }

  /// 空行だけ送っても要求にならず、応答も出ない。
  func testEmptyLinesProduceNoResponse() {
    let wire = startWire(target: FakeControlTarget())

    wire.sendRaw(Data("\n\n\n".utf8))

    wire.barrier()
  }

  /// 改行の来ないまま 1 行が上限（1 MiB）を超えたら接続を畳む（メモリ枯渇防止）。
  func testOverlongLineWithoutNewlineDisconnects() {
    let wire = startWire(target: FakeControlTarget())

    wire.sendRaw(Data(repeating: 0x78, count: (1 << 20) + 4096))  // 'x' を上限超まで、改行なし

    wire.waitForDisconnect()
  }
}
