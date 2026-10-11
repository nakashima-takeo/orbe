import Foundation
import XCTest

@testable import Orbe

/// ボードの部品の 3 動詞の params の語と型検査と、domain への配線。
///
/// 壊れると何が起きるか: 真偽値の true が workspace の 1 番として読まれ、別の workspace のボードを触る。知らない種類が黙って
/// 何かに読み替えられる。置くと外すが入れ替わって配線され、AI が外したつもりの部品が残る。
extension ControlWireTests {
  /// 3 動詞の正しい params 一式（`validRequests` の一部）。
  var boardRequests: [(method: String, params: [String: Any])] {
    [
      ("list_board_parts", ["workspaceId": 3]),
      ("add_board_part", ["workspaceId": 3, "kind": "intake"]),
      ("remove_board_part", ["workspaceId": 3, "kind": "intake"]),
    ]
  }

  func testBoardVerbsReachTheirOwnDomainOperation() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    let listed = wire.request(id: 1, method: "list_board_parts", params: ["workspaceId": 3])
    _ = wire.request(id: 2, method: "add_board_part", params: ["workspaceId": 4, "kind": "intake"])
    _ = wire.request(
      id: 3, method: "remove_board_part", params: ["workspaceId": 5, "kind": "intake"])

    XCTAssertEqual(
      ((listed?["result"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["kind"]
        as? String, "intake", "結果の並びは parts で包む")
    XCTAssertEqual(fake.boardLists, [3])
    XCTAssertEqual(fake.addedBoardParts.map(\.workspaceId), [4])
    XCTAssertEqual(fake.addedBoardParts.map(\.part), [.intake])
    XCTAssertEqual(fake.removedBoardParts.map(\.workspaceId), [5])
    XCTAssertEqual(fake.removedBoardParts.map(\.part), [.intake])
  }

  func testBoardVerbsCheckTheirParams() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    struct Case {
      let label: String
      let method: String
      let params: [String: Any]
      let message: String
    }
    let cases = [
      Case(
        label: "真偽値は workspace の番号でない", method: "list_board_parts", params: ["workspaceId": true],
        message: "invalid workspaceId"),
      Case(
        label: "文字列の番号", method: "add_board_part", params: ["workspaceId": "3", "kind": "intake"],
        message: "invalid workspaceId"),
      Case(
        label: "種類が文字列でない", method: "add_board_part", params: ["workspaceId": 3, "kind": 1],
        message: "invalid kind"),
      Case(
        label: "知らない種類", method: "remove_board_part",
        params: ["workspaceId": 3, "kind": "weather"],
        message: "unknown kind: weather (known: intake)"),
    ]
    for item in cases {
      let response = wire.request(id: 1, method: item.method, params: item.params)
      XCTAssertEqual(errorCode(response), -32602, item.label)
      XCTAssertEqual(
        (response?["error"] as? [String: Any])?["message"] as? String, item.message, item.label)
    }
    XCTAssertTrue(fake.boardLists.isEmpty && fake.addedBoardParts.isEmpty, "target へ届かない")
    XCTAssertTrue(fake.removedBoardParts.isEmpty, "target へ届かない")
  }
}
