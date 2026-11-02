import Foundation
import XCTest

@testable import Orbe

/// ボードのウィジェットの 3 動詞の params の語と型検査と、domain への配線。
///
/// 壊れると何が起きるか: workspace の ID でない値が読み替えられ、別の workspace のボードを触る。知らない種類が黙って
/// 何かに読み替えられる。置くと外すが入れ替わって配線され、AI が外したつもりのウィジェットが残る。
extension ControlWireTests {
  /// 3 動詞の正しい params 一式（`validRequests` の一部）。
  var boardRequests: [(method: String, params: [String: Any])] {
    [
      ("list_board_widgets", ["workspaceId": Self.workspace]),
      ("add_board_widget", ["workspaceId": Self.workspace, "kind": "automation"]),
      ("remove_board_widget", ["workspaceId": Self.workspace, "kind": "automation"]),
    ]
  }

  func testBoardVerbsReachTheirOwnDomainOperation() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    let (listedIn, addedTo, removedFrom) = (UUID(), UUID(), UUID())

    let listed = wire.request(
      id: 1, method: "list_board_widgets", params: ["workspaceId": listedIn.uuidString])
    _ = wire.request(
      id: 2, method: "add_board_widget",
      params: ["workspaceId": addedTo.uuidString, "kind": "automation"])
    _ = wire.request(
      id: 3, method: "remove_board_widget",
      params: ["workspaceId": removedFrom.uuidString, "kind": "automation"])

    XCTAssertEqual(
      ((listed?["result"] as? [String: Any])?["widgets"] as? [[String: Any]])?.first?["kind"]
        as? String, "automation", "結果の並びは widgets で包む")
    XCTAssertEqual(fake.boardLists, [listedIn])
    XCTAssertEqual(fake.addedBoardWidgets.map(\.workspaceId), [addedTo])
    XCTAssertEqual(fake.addedBoardWidgets.map(\.widget), [.automation])
    XCTAssertEqual(fake.removedBoardWidgets.map(\.workspaceId), [removedFrom])
    XCTAssertEqual(fake.removedBoardWidgets.map(\.widget), [.automation])
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
        label: "真偽値は workspace の ID でない", method: "list_board_widgets",
        params: ["workspaceId": true], message: "invalid workspaceId"),
      Case(
        label: "整数は workspace の ID でない", method: "add_board_widget",
        params: ["workspaceId": 3, "kind": "automation"],
        message: "invalid workspaceId"),
      Case(
        label: "種類が文字列でない", method: "add_board_widget",
        params: ["workspaceId": Self.workspace, "kind": 1], message: "invalid kind"),
      Case(
        label: "知らない種類", method: "remove_board_widget",
        params: ["workspaceId": Self.workspace, "kind": "weather"],
        message: "unknown kind: weather (known: automation)"),
    ]
    for item in cases {
      let response = wire.request(id: 1, method: item.method, params: item.params)
      XCTAssertEqual(errorCode(response), -32602, item.label)
      XCTAssertEqual(
        (response?["error"] as? [String: Any])?["message"] as? String, item.message, item.label)
    }
    XCTAssertTrue(fake.boardLists.isEmpty && fake.addedBoardWidgets.isEmpty, "target へ届かない")
    XCTAssertTrue(fake.removedBoardWidgets.isEmpty, "target へ届かない")
  }
}
